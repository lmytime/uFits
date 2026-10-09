/*
 * fq.c - uFits core: FITS parsing, image selection, binning, stretching.
 *
 * Pipeline for an image:
 *   1. memory map the file (or inflate it on demand if it is gzipped)
 *   2. walk the headers until the first HDU holding image data
 *   3. pick a bin factor so the result fits the requested box, and the
 *      sample positions inside each bin
 *   4. bin the source rows into a small float image, in parallel; for tile
 *      compressed data only the tiles covering sampled rows are decoded
 *   5. estimate median / MAD from a subsample, build the stretch
 *   6. map to 8 bit gray (or RGBA when there is colour or missing data)
 */
#define _DEFAULT_SOURCE 1
#define _DARWIN_C_SOURCE 1

#include "fq.h"
#include "fq_internal.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

#define CARD 80
#define BLOCK 2880
#define MAX_HDUS 100000
#define BIG ((int64_t)1 << 62)
#define GZ_LIMIT ((int64_t)2 << 30)     /* never inflate more than 2 GiB */
#define STAT_SAMPLES 200000
#define MAX_K 64
#define N_RANDOM 10000

/* ------------------------------------------------------------ utilities */

static void seterr(char *err, size_t n, const char *fmt, ...)
{
    if (!err || !n)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, n, fmt, ap);
    va_end(ap);
}

static int64_t mul_sat(int64_t a, int64_t b)
{
    if (a < 0 || b < 0)
        return BIG;
    if (a == 0 || b == 0)
        return 0;
    if (a > BIG / b)
        return BIG;
    return a * b;
}

static int64_t add_sat(int64_t a, int64_t b)
{
    if (a >= BIG || b >= BIG || a > BIG - b)
        return BIG;
    return a + b;
}

static inline int is_finite(float v) { return (v - v) == 0.0f; }

/* Bounded string copy that always terminates. */
static void scopy(char *dst, size_t n, const char *src)
{
    size_t i = 0;
    for (; src[i] && i + 1 < n; i++)
        dst[i] = src[i];
    dst[i] = 0;
}


/* --------------------------------------------------------- parallel for */

typedef void (*task_fn)(void *ctx, size_t i);

#if defined(__APPLE__)
static void par_for(size_t n, int threads, void *ctx, task_fn fn)
{
    if (n == 0)
        return;
    if (n == 1 || threads == 1) {
        for (size_t i = 0; i < n; i++)
            fn(ctx, i);
        return;
    }
    dispatch_apply_f(n, DISPATCH_APPLY_AUTO, ctx, fn);
}
#else
static int ncpu(void)
{
    static int n = 0;
    if (!n) {
        long c = sysconf(_SC_NPROCESSORS_ONLN);
        n = c < 1 ? 1 : (c > 64 ? 64 : (int)c);
    }
    return n;
}

typedef struct {
    size_t n, next;
    void *ctx;
    task_fn fn;
} pf_job;

static void *pf_worker(void *arg)
{
    pf_job *p = arg;
    for (;;) {
        size_t i = __atomic_fetch_add(&p->next, 1, __ATOMIC_RELAXED);
        if (i >= p->n)
            break;
        p->fn(p->ctx, i);
    }
    return NULL;
}

static void par_for(size_t n, int threads, void *ctx, task_fn fn)
{
    if (n == 0)
        return;
    int nt = threads > 0 ? threads : ncpu();
    if ((size_t)nt > n)
        nt = (int)n;
    if (nt > 64)
        nt = 64;
    if (nt <= 1) {
        for (size_t i = 0; i < n; i++)
            fn(ctx, i);
        return;
    }
    pf_job job = { n, 0, ctx, fn };
    pthread_t th[64];
    int started = 0;
    for (int t = 1; t < nt; t++)
        if (pthread_create(&th[started], NULL, pf_worker, &job) == 0)
            started++;
    pf_worker(&job);
    for (int t = 0; t < started; t++)
        pthread_join(th[t], NULL);
}
#endif

/* ------------------------------------------------------------- the file */

typedef struct {
    int64_t hdr_off, hdr_len, data_off, data_len, next_off;
    int bitpix, naxis;
    int64_t naxes[FQ_MAXAXES];
    int64_t pcount, gcount;
    double bscale, bzero;
    int has_blank;
    int64_t blank;
    int groups, zimage;
    char xtension[20];
    char extname[72];
} hdu_t;

struct fq_file {
    const uint8_t *data;     /* bytes available so far */
    int64_t size;
    void *map;               /* mmap of the file on disk */
    size_t maplen;
    uint8_t *owned;          /* malloc'd data (copy or inflated) */
    int64_t cap;
    z_stream *z;             /* gzip input still being inflated */
    const uint8_t *gzsrc;
    size_t gzlen, gzpos;
    int gz_done;
    hdu_t *hdu;
    int nhdu, hcap;
    int64_t scan_off;
    int scan_done;
};

/* Make bytes [0, end) available when the file is being inflated lazily.
   Returns the number of bytes available. Invalidates pointers into data. */
static int64_t need(fq_file *f, int64_t end)
{
    if (!f->z || f->gz_done || end <= f->size)
        return f->size;
    int64_t want = add_sat(end, (int64_t)1 << 20);
    if (want > GZ_LIMIT)
        want = GZ_LIMIT;
    if (want > f->cap) {
        int64_t ncap = f->cap ? f->cap : (int64_t)1 << 20;
        while (ncap < want)
            ncap *= 2;
        if (ncap > GZ_LIMIT)
            ncap = GZ_LIMIT;
        uint8_t *p = realloc(f->owned, (size_t)ncap);
        if (!p) {
            f->gz_done = 1;
            return f->size;
        }
        f->owned = p;
        f->data = p;
        f->cap = ncap;
    }
    z_stream *z = f->z;
    while (f->size < want) {
        if (z->avail_in == 0 && f->gzpos < f->gzlen) {
            size_t chunk = f->gzlen - f->gzpos;
            if (chunk > (1u << 30))
                chunk = 1u << 30;
            z->next_in = (Bytef *)(f->gzsrc + f->gzpos);
            z->avail_in = (uInt)chunk;
            f->gzpos += chunk;
        }
        int64_t room = f->cap - f->size;
        if (room > (1 << 30))
            room = 1 << 30;
        z->next_out = f->owned + f->size;
        z->avail_out = (uInt)room;
        int rc = inflate(z, Z_NO_FLUSH);
        f->size += room - (int64_t)z->avail_out;
        if (rc == Z_STREAM_END) {
            if (z->avail_in >= 2 && z->next_in[0] == 0x1f && z->next_in[1] == 0x8b) {
                inflateReset(z);
                continue;
            }
            f->gz_done = 1;
            break;
        }
        if (rc != Z_OK) {
            f->gz_done = 1;
            break;
        }
    }
    return f->size;
}

static fq_file *finish_open(fq_file *f, const uint8_t *bytes, size_t len,
                            char *err, size_t errlen)
{
    if (len >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        f->z = calloc(1, sizeof *f->z);
        if (!f->z || inflateInit2(f->z, 15 + 32) != Z_OK) {
            free(f->z);
            f->z = NULL;
            fq_close(f);
            seterr(err, errlen, "cannot start gzip decompression");
            return NULL;
        }
        f->gzsrc = bytes;
        f->gzlen = len;
        f->data = NULL;
        f->size = 0;
        need(f, BLOCK);
    } else {
        f->data = bytes;
        f->size = (int64_t)len;
    }
    if (f->size < CARD || memcmp(f->data, "SIMPLE  =", 9) != 0) {
        fq_close(f);
        seterr(err, errlen, "not a FITS file");
        return NULL;
    }
    return f;
}

fq_file *fq_open(const char *path, char *err, size_t errlen)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        seterr(err, errlen, "cannot open file: %s", strerror(errno));
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        seterr(err, errlen, "not a regular file");
        return NULL;
    }
    if (st.st_size < CARD) {
        close(fd);
        seterr(err, errlen, "file too small to be FITS");
        return NULL;
    }
    size_t len = (size_t)st.st_size;
    void *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) {
        seterr(err, errlen, "cannot map file: %s", strerror(errno));
        return NULL;
    }
    fq_file *f = calloc(1, sizeof *f);
    if (!f) {
        munmap(m, len);
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    f->map = m;
    f->maplen = len;
    return finish_open(f, m, len, err, errlen);
}

fq_file *fq_open_memory(const void *data, size_t size, int copy, char *err, size_t errlen)
{
    if (!data || size < CARD) {
        seterr(err, errlen, "buffer too small to be FITS");
        return NULL;
    }
    fq_file *f = calloc(1, sizeof *f);
    if (!f) {
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    const uint8_t *bytes = data;
    if (copy) {
        uint8_t *p = malloc(size);
        if (!p) {
            free(f);
            seterr(err, errlen, "out of memory");
            return NULL;
        }
        memcpy(p, data, size);
        /* Inflated output goes to owned, so keep a compressed copy apart. */
        if (size >= 2 && p[0] == 0x1f && p[1] == 0x8b) {
            f->map = p;          /* freed in fq_close via maplen == 0 path */
            f->maplen = 0;
        } else {
            f->owned = p;
        }
        bytes = p;
    }
    return finish_open(f, bytes, size, err, errlen);
}

void fq_close(fq_file *f)
{
    if (!f)
        return;
    if (f->z) {
        inflateEnd(f->z);
        free(f->z);
    }
    if (f->map) {
        if (f->maplen)
            munmap(f->map, f->maplen);
        else
            free(f->map);
    }
    free(f->owned);
    free(f->hdu);
    free(f);
}

/* ------------------------------------------------------- header cards */

static int key_is(const char *c, const char *key)
{
    int i = 0;
    for (; i < 8 && key[i]; i++)
        if (c[i] != key[i])
            return 0;
    if (key[i])
        return 0;
    for (; i < 8; i++)
        if (c[i] != ' ')
            return 0;
    return 1;
}

static inline char printable(char ch)
{
    return (ch >= 32 && ch < 127) ? ch : '?';
}

/* Value of a card: strings are unquoted with trailing blanks removed,
   other values are returned as the raw token without the comment.
   Anything that is not printable ASCII becomes '?'.
   Returns 1 for a string, 0 for another value, -1 if there is none. */
static int card_value(const char *c, char *out, size_t outlen)
{
    if (!outlen)
        return -1;
    out[0] = 0;
    if (c[8] != '=')
        return -1;
    int i = 9;
    while (i < CARD && c[i] == ' ')
        i++;
    size_t o = 0;
    if (i < CARD && c[i] == '\'') {
        for (i++; i < CARD; i++) {
            if (c[i] == '\'') {
                if (i + 1 < CARD && c[i + 1] == '\'') {
                    if (o + 1 < outlen)
                        out[o++] = '\'';
                    i++;
                    continue;
                }
                break;
            }
            if (o + 1 < outlen)
                out[o++] = printable(c[i]);
        }
        while (o > 0 && out[o - 1] == ' ')
            o--;
        out[o] = 0;
        return 1;
    }
    for (; i < CARD && c[i] != '/'; i++)
        if (o + 1 < outlen)
            out[o++] = printable(c[i]);
    while (o > 0 && out[o - 1] == ' ')
        o--;
    out[o] = 0;
    return 0;
}

static int parse_dbl(const char *s, double *v)
{
    char tmp[CARD];
    size_t n = 0;
    for (; s[n] && n + 1 < sizeof tmp; n++)
        tmp[n] = (s[n] == 'D' || s[n] == 'd') ? 'E' : s[n];
    tmp[n] = 0;
    char *end;
    double d = strtod(tmp, &end);
    if (end == tmp)
        return 0;
    *v = d;
    return 1;
}

static int parse_int(const char *s, int64_t *v)
{
    char *end;
    errno = 0;
    long long x = strtoll(s, &end, 10);
    if (end != s && errno == 0) {
        while (*end == ' ')
            end++;
        if (*end == 0) {
            *v = x;
            return 1;
        }
    }
    double d;
    if (!parse_dbl(s, &d) || !(fabs(d) < 9.0e18))
        return 0;
    *v = (int64_t)d;
    return 1;
}

/* ------------------------------------------------------------ headers */

static int parse_header(fq_file *f, int64_t off, hdu_t *h, int primary)
{
    memset(h, 0, sizeof *h);
    h->hdr_off = off;
    h->bscale = 1.0;
    h->gcount = 1;
    if (need(f, off + BLOCK) < off + BLOCK)
        return -1;
    const char *first = (const char *)f->data + off;
    if (!key_is(first, primary ? "SIMPLE" : "XTENSION"))
        return -1;

    int64_t pos = off, extra = 1;
    int ended = 0;
    char v[CARD];
    int64_t iv;
    double dv;
    while (!ended) {
        if (need(f, pos + BLOCK) < pos + BLOCK)
            return -1;
        const char *blk = (const char *)f->data + pos;
        for (int i = 0; i < 36 && !ended; i++) {
            const char *c = blk + i * CARD;
            switch (c[0]) {
            case 'E':
                if (key_is(c, "END"))
                    ended = 1;
                else if (key_is(c, "EXTNAME") && card_value(c, v, sizeof v) >= 0)
                    scopy(h->extname, sizeof h->extname, v);
                break;
            case 'X':
                if (key_is(c, "XTENSION") && card_value(c, v, sizeof v) >= 0) {
                    size_t k = 0;
                    for (; v[k] && k + 1 < sizeof h->xtension; k++)
                        h->xtension[k] = (char)toupper((unsigned char)v[k]);
                    h->xtension[k] = 0;
                }
                break;
            case 'B':
                if (key_is(c, "BITPIX")) {
                    if (card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                        h->bitpix = (int)iv;
                } else if (key_is(c, "BSCALE")) {
                    if (card_value(c, v, sizeof v) >= 0 && parse_dbl(v, &dv) && dv != 0)
                        h->bscale = dv;
                } else if (key_is(c, "BZERO")) {
                    if (card_value(c, v, sizeof v) >= 0 && parse_dbl(v, &dv))
                        h->bzero = dv;
                } else if (key_is(c, "BLANK")) {
                    if (card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv)) {
                        h->has_blank = 1;
                        h->blank = iv;
                    }
                }
                break;
            case 'N':
                if (memcmp(c, "NAXIS", 5) == 0 && card_value(c, v, sizeof v) >= 0 &&
                    parse_int(v, &iv)) {
                    if (key_is(c, "NAXIS")) {
                        if (iv < 0 || iv > 999)
                            return -1;
                        h->naxis = (int)iv;
                    } else {
                        int n = 0, j = 5;
                        for (; j < 8 && isdigit((unsigned char)c[j]); j++)
                            n = n * 10 + (c[j] - '0');
                        int ok = j > 5 && n >= 1;
                        for (; j < 8; j++)
                            if (c[j] != ' ')
                                ok = 0;
                        if (!ok)
                            break;
                        if (iv < 0)
                            return -1;
                        if (n <= FQ_MAXAXES)
                            h->naxes[n - 1] = iv;
                        else
                            extra = mul_sat(extra, iv);
                    }
                }
                break;
            case 'P':
                if (key_is(c, "PCOUNT") && card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                    h->pcount = iv;
                break;
            case 'G':
                if (key_is(c, "GCOUNT")) {
                    if (card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                        h->gcount = iv;
                } else if (key_is(c, "GROUPS")) {
                    if (card_value(c, v, sizeof v) >= 0)
                        h->groups = v[0] == 'T';
                }
                break;
            case 'Z':
                if (key_is(c, "ZIMAGE") && card_value(c, v, sizeof v) >= 0)
                    h->zimage = v[0] == 'T';
                break;
            }
        }
        pos += BLOCK;
        if (pos - off > ((int64_t)64 << 20))
            return -1;
    }
    h->hdr_len = pos - off;
    h->data_off = pos;

    int b = h->bitpix;
    if (b != 8 && b != 16 && b != 32 && b != 64 && b != -32 && b != -64)
        return -1;
    int64_t nelem = 0;
    if (h->naxis > 0) {
        nelem = 1;
        int start = (h->groups && h->naxes[0] == 0) ? 1 : 0;
        for (int i = start; i < h->naxis && i < FQ_MAXAXES; i++)
            nelem = mul_sat(nelem, h->naxes[i]);
        nelem = mul_sat(nelem, extra);
        nelem = mul_sat(h->gcount, add_sat(h->pcount < 0 ? BIG : h->pcount, nelem));
    }
    int64_t bytes = mul_sat(nelem, (b < 0 ? -b : b) / 8);
    if (bytes >= BIG)
        return -1;
    h->data_len = bytes;
    h->next_off = add_sat(h->data_off, (bytes + BLOCK - 1) / BLOCK * BLOCK);
    return 0;
}

/* HDU idx, parsing headers as needed. The pointer is only valid until the
   next call. */
static hdu_t *get_hdu(fq_file *f, int idx)
{
    while (f->nhdu <= idx && !f->scan_done) {
        if (f->nhdu >= MAX_HDUS) {
            f->scan_done = 1;
            break;
        }
        hdu_t h;
        if (parse_header(f, f->scan_off, &h, f->nhdu == 0) != 0) {
            f->scan_done = 1;
            break;
        }
        if (f->nhdu == f->hcap) {
            int ncap = f->hcap ? f->hcap * 2 : 8;
            hdu_t *p = realloc(f->hdu, (size_t)ncap * sizeof *p);
            if (!p) {
                f->scan_done = 1;
                break;
            }
            f->hdu = p;
            f->hcap = ncap;
        }
        f->hdu[f->nhdu++] = h;
        f->scan_off = h.next_off;
        if (h.next_off >= BIG)
            f->scan_done = 1;
    }
    return idx >= 0 && idx < f->nhdu ? &f->hdu[idx] : NULL;
}

int fq_hdu_count(fq_file *f)
{
    get_hdu(f, MAX_HDUS);
    return f->nhdu;
}

static const char *hdu_card(const fq_file *f, const hdu_t *h, const char *key)
{
    const char *p = (const char *)f->data + h->hdr_off;
    int64_t n = h->hdr_len / CARD;
    for (int64_t i = 0; i < n; i++) {
        const char *c = p + i * CARD;
        if (key_is(c, key))
            return c;
        if (c[0] == 'E' && key_is(c, "END"))
            break;
    }
    return NULL;
}

static int kw_str(const fq_file *f, const hdu_t *h, const char *key, char *out, size_t n)
{
    const char *c = hdu_card(f, h, key);
    return c && card_value(c, out, n) >= 0;
}

static int kw_int(const fq_file *f, const hdu_t *h, const char *key, int64_t *v)
{
    char b[CARD];
    return kw_str(f, h, key, b, sizeof b) && parse_int(b, v);
}

static int kw_dbl(const fq_file *f, const hdu_t *h, const char *key, double *v)
{
    char b[CARD];
    return kw_str(f, h, key, b, sizeof b) && parse_dbl(b, v);
}

int fq_keyword(fq_file *f, int idx, const char *key, char *val, size_t vallen)
{
    hdu_t *h = get_hdu(f, idx);
    if (!h || !val || !vallen)
        return 0;
    return kw_str(f, h, key, val, vallen);
}

/* -------------------------------------------------- compressed images */

enum { ALG_NONE, ALG_RICE, ALG_GZIP1, ALG_GZIP2, ALG_PLIO, ALG_UNSUPPORTED };
enum { Q_LOSSLESS, Q_NODITHER, Q_SD1, Q_SD2 };

typedef struct {
    int present;
    int64_t off;   /* byte offset in the row */
    char type;     /* element type letter */
    char desc;     /* 'P' or 'Q' for variable length arrays, 0 otherwise */
} col_t;

typedef struct {
    int algo;
    int zbitpix, znaxis;
    int64_t znaxes[FQ_MAXAXES], ztile[FQ_MAXAXES], ntile[FQ_MAXAXES];
    int blocksize, bytepix;
    int quant;
    int64_t zdither0;
    int has_zblank;
    int64_t zblank;
    int has_zscale_kw;
    double zscale_kw, zzero_kw;
    col_t cdata, gzdata, udata, zscale, zzero, zblankc;
    const uint8_t *tab;
    int64_t avail, rowlen, nrows, theap;
    double bscale, bzero;
    int64_t maxtile;
} comp_t;

static int64_t elem_size(char t)
{
    switch (t) {
    case 'L': case 'B': case 'A': case 'X': return 1;
    case 'I': return 2;
    case 'J': case 'E': return 4;
    case 'K': case 'D': case 'C': case 'P': return 8;
    case 'M': case 'Q': return 16;
    }
    return 0;
}

/* Parse a TFORM value. Returns the column width in bytes, or -1. */
static int64_t parse_tform(const char *s, char *type, char *desc)
{
    while (*s == ' ')
        s++;
    int64_t rep = 1;
    if (isdigit((unsigned char)*s)) {
        rep = 0;
        while (isdigit((unsigned char)*s) && rep < BIG / 10)
            rep = rep * 10 + (*s++ - '0');
    }
    char t = (char)toupper((unsigned char)*s);
    if (!t)
        return -1;
    *desc = 0;
    *type = t;
    if (t == 'P' || t == 'Q') {
        char e = (char)toupper((unsigned char)s[1]);
        *desc = t;
        *type = e ? e : 'B';
        return rep ? (t == 'P' ? 8 : 16) : 0;
    }
    if (t == 'X')
        return (rep + 7) / 8;
    int64_t es = elem_size(t);
    if (!es)
        return -1;
    return mul_sat(rep, es);
}

static int parse_comp(fq_file *f, const hdu_t *h, comp_t *c, char *cmp, size_t cmplen)
{
    memset(c, 0, sizeof *c);
    char v[CARD];
    int64_t iv;
    cmp[0] = 0;
    if (kw_str(f, h, "ZCMPTYPE", v, sizeof v))
        scopy(cmp, cmplen, v);
    if (!strcasecmp(cmp, "RICE_1") || !strcasecmp(cmp, "RICE_ONE"))
        c->algo = ALG_RICE;
    else if (!strcasecmp(cmp, "GZIP_1"))
        c->algo = ALG_GZIP1;
    else if (!strcasecmp(cmp, "GZIP_2"))
        c->algo = ALG_GZIP2;
    else if (!strcasecmp(cmp, "PLIO_1"))
        c->algo = ALG_PLIO;
    else if (!strcasecmp(cmp, "NOCOMPRESS"))
        c->algo = ALG_NONE;
    else
        c->algo = ALG_UNSUPPORTED;

    if (!kw_int(f, h, "ZBITPIX", &iv))
        return -1;
    c->zbitpix = (int)iv;
    int b = c->zbitpix;
    if (b != 8 && b != 16 && b != 32 && b != 64 && b != -32 && b != -64)
        return -1;
    if (!kw_int(f, h, "ZNAXIS", &iv) || iv < 1 || iv > FQ_MAXAXES)
        return -1;
    c->znaxis = (int)iv;
    char key[32];
    for (int a = 0; a < c->znaxis; a++) {
        snprintf(key, sizeof key, "ZNAXIS%d", a + 1);
        if (!kw_int(f, h, key, &iv) || iv < 1 || iv > INT_MAX)
            return -1;
        c->znaxes[a] = iv;
        snprintf(key, sizeof key, "ZTILE%d", a + 1);
        if (!kw_int(f, h, key, &iv) || iv < 1)
            iv = a == 0 ? c->znaxes[0] : 1;
        c->ztile[a] = iv > c->znaxes[a] ? c->znaxes[a] : iv;
    }
    if (c->znaxis == 1) {   /* treat a 1-D image as one row */
        c->znaxis = 2;
        c->znaxes[1] = 1;
        c->ztile[1] = 1;
    }
    c->maxtile = 1;
    int64_t npix = 1;
    for (int a = 0; a < c->znaxis; a++) {
        c->ntile[a] = (c->znaxes[a] - 1) / c->ztile[a] + 1;
        c->maxtile = mul_sat(c->maxtile, c->ztile[a]);
        npix = mul_sat(npix, c->znaxes[a]);
    }
    if (c->maxtile > ((int64_t)1 << 28) || npix > ((int64_t)1 << 40))
        return -1;

    c->blocksize = 32;
    c->bytepix = 4;
    for (int i = 1; i <= 32; i++) {
        snprintf(key, sizeof key, "ZNAME%d", i);
        if (!kw_str(f, h, key, v, sizeof v))
            break;
        snprintf(key, sizeof key, "ZVAL%d", i);
        if (!kw_int(f, h, key, &iv))
            continue;
        if (!strcasecmp(v, "BLOCKSIZE"))
            c->blocksize = (int)iv;
        else if (!strcasecmp(v, "BYTEPIX"))
            c->bytepix = (int)iv;
    }
    if (c->blocksize < 1 || c->blocksize > 1 << 20)
        c->blocksize = 32;

    c->quant = Q_NODITHER;
    if (kw_str(f, h, "ZQUANTIZ", v, sizeof v)) {
        if (!strcasecmp(v, "SUBTRACTIVE_DITHER_1"))
            c->quant = Q_SD1;
        else if (!strcasecmp(v, "SUBTRACTIVE_DITHER_2"))
            c->quant = Q_SD2;
        else if (!strcasecmp(v, "NONE"))
            c->quant = Q_LOSSLESS;
    }
    c->zdither0 = 1;
    if (kw_int(f, h, "ZDITHER0", &iv))
        c->zdither0 = iv;
    if (kw_int(f, h, "ZBLANK", &iv)) {
        c->has_zblank = 1;
        c->zblank = iv;
    } else if (h->has_blank) {
        c->has_zblank = 1;
        c->zblank = h->blank;
    }
    double dv;
    if (kw_dbl(f, h, "ZSCALE", &dv)) {
        c->has_zscale_kw = 1;
        c->zscale_kw = dv;
        if (!kw_dbl(f, h, "ZZERO", &c->zzero_kw))
            c->zzero_kw = 0;
    }
    c->bscale = h->bscale;
    c->bzero = h->bzero;

    /* Columns of the binary table. */
    int64_t tfields = 0;
    if (!kw_int(f, h, "TFIELDS", &tfields) || tfields < 1 || tfields > 999)
        return -1;
    int64_t off = 0;
    for (int n = 1; n <= tfields; n++) {
        char form[CARD], name[CARD] = "";
        snprintf(key, sizeof key, "TFORM%d", n);
        if (!kw_str(f, h, key, form, sizeof form))
            return -1;
        char type, desc;
        int64_t width = parse_tform(form, &type, &desc);
        if (width < 0)
            return -1;
        snprintf(key, sizeof key, "TTYPE%d", n);
        kw_str(f, h, key, name, sizeof name);
        col_t col = { 1, off, type, desc };
        if (!strcasecmp(name, "COMPRESSED_DATA") && desc)
            c->cdata = col;
        else if (!strcasecmp(name, "GZIP_COMPRESSED_DATA") && desc)
            c->gzdata = col;
        else if (!strcasecmp(name, "UNCOMPRESSED_DATA") && desc)
            c->udata = col;
        else if (!strcasecmp(name, "ZSCALE") && !desc)
            c->zscale = col;
        else if (!strcasecmp(name, "ZZERO") && !desc)
            c->zzero = col;
        else if (!strcasecmp(name, "ZBLANK") && !desc)
            c->zblankc = col;
        off = add_sat(off, width);
    }
    c->rowlen = h->naxes[0];
    c->nrows = h->naxis >= 2 ? h->naxes[1] : 0;
    if (off > c->rowlen || !c->cdata.present)
        return -1;
    c->theap = mul_sat(c->rowlen, c->nrows);
    if (kw_int(f, h, "THEAP", &iv) && iv >= c->theap)
        c->theap = iv;
    return 0;
}

static int read_desc(const uint8_t *row, const col_t *col, int64_t *count, int64_t *off)
{
    const uint8_t *p = row + col->off;
    if (col->desc == 'P') {
        *count = (int64_t)fq_be32(p);
        *off = (int64_t)fq_be32(p + 4);
    } else {
        *count = (int64_t)fq_be64(p);
        *off = (int64_t)fq_be64(p + 8);
    }
    return *count >= 0 && *off >= 0;
}

static double col_double(const uint8_t *row, const col_t *col)
{
    const uint8_t *p = row + col->off;
    switch (col->type) {
    case 'D': { uint64_t u = fq_be64(p); double d; memcpy(&d, &u, 8); return d; }
    case 'E': { uint32_t u = fq_be32(p); float x; memcpy(&x, &u, 4); return x; }
    case 'J': return (int32_t)fq_be32(p);
    case 'K': return (double)(int64_t)fq_be64(p);
    case 'I': return (int16_t)fq_be16(p);
    case 'B': return p[0];
    }
    return 0;
}

static int64_t col_int(const uint8_t *row, const col_t *col)
{
    const uint8_t *p = row + col->off;
    switch (col->type) {
    case 'J': return (int32_t)fq_be32(p);
    case 'K': return (int64_t)fq_be64(p);
    case 'I': return (int16_t)fq_be16(p);
    case 'B': return p[0];
    }
    return (int64_t)col_double(row, col);
}

static float g_rand[N_RANDOM];
static pthread_once_t g_rand_once = PTHREAD_ONCE_INIT;

/* The portable random sequence the FITS standard uses for dithering. */
static void init_rand(void)
{
    double a = 16807.0, m = 2147483647.0, seed = 1;
    for (int i = 0; i < N_RANDOM; i++) {
        double t = a * seed;
        seed = t - m * (double)(int64_t)(t / m);
        g_rand[i] = (float)(seed / m);
    }
}

typedef struct {
    int32_t *ibuf;   /* maxtile integers */
    uint8_t *bbuf;   /* 2 * 8 * maxtile bytes */
} tscratch;

/* Decode tile t (npix pixels) into physical values minus ref. */
static int decode_tile(const comp_t *c, int64_t t, int64_t npix, float *out,
                       tscratch *s, double ref)
{
    if (t < 0 || t >= c->nrows || (t + 1) * c->rowlen > c->avail)
        return -1;
    const uint8_t *row = c->tab + t * c->rowlen;
    int64_t cnt = 0, hoff = 0;
    int src = 0;
    const col_t *col = NULL;
    if (read_desc(row, &c->cdata, &cnt, &hoff) && cnt > 0) {
        src = 1;
        col = &c->cdata;
    } else if (c->gzdata.present && read_desc(row, &c->gzdata, &cnt, &hoff) && cnt > 0) {
        src = 2;
        col = &c->gzdata;
    } else if (c->udata.present && read_desc(row, &c->udata, &cnt, &hoff) && cnt > 0) {
        src = 3;
        col = &c->udata;
    } else {
        return -1;
    }
    int64_t esz = elem_size(col->type);
    if (!esz)
        return -1;
    int64_t nbytes = mul_sat(cnt, esz);
    int64_t start = add_sat(c->theap, hoff);
    if (add_sat(start, nbytes) > c->avail)
        return -1;
    const uint8_t *data = c->tab + start;

    const uint8_t *raw = NULL;  /* big-endian values of rawsize bytes */
    int rawsize = 0;
    int ints = 0;               /* values are in s->ibuf */
    int isfloat = 0;            /* raw holds IEEE floats */
    const int64_t bcap = npix * 8;

    if (src == 1) {
        switch (c->algo) {
        case ALG_RICE:
            if (fq_rice_decode(data, (size_t)nbytes, s->ibuf, npix, c->blocksize, c->bytepix))
                return -1;
            ints = 1;
            break;
        case ALG_PLIO: {
            if (col->type != 'I' || cnt * 2 > bcap)
                return -1;
            int16_t *ll = (int16_t *)(void *)s->bbuf;
            for (int64_t i = 0; i < cnt; i++)
                ll[i] = (int16_t)fq_be16(data + 2 * i);
            if (fq_plio_decode(ll, (size_t)cnt, s->ibuf, npix))
                return -1;
            ints = 1;
            break;
        }
        case ALG_GZIP1:
        case ALG_GZIP2: {
            int64_t got = fq_inflate(data, (size_t)nbytes, s->bbuf, (size_t)bcap);
            if (got <= 0 || got % npix)
                return -1;
            rawsize = (int)(got / npix);
            raw = s->bbuf;
            if (c->algo == ALG_GZIP2 && rawsize > 1) {
                fq_unshuffle(s->bbuf, s->bbuf + bcap, npix, rawsize);
                raw = s->bbuf + bcap;
            }
            break;
        }
        case ALG_NONE:
            if (nbytes % npix)
                return -1;
            rawsize = (int)(nbytes / npix);
            raw = data;
            break;
        default:
            return -1;
        }
    } else if (src == 2) {
        int64_t got = fq_inflate(data, (size_t)nbytes, s->bbuf, (size_t)bcap);
        if (got <= 0 || got % npix)
            return -1;
        rawsize = (int)(got / npix);
        raw = s->bbuf;
        isfloat = 1;
    } else {
        if (cnt != npix)
            return -1;
        rawsize = (int)esz;
        raw = data;
        isfloat = col->type == 'E' || col->type == 'D';
    }
    if (raw && rawsize != 1 && rawsize != 2 && rawsize != 4 && rawsize != 8)
        return -1;

    const int quantized = src == 1 && c->zbitpix < 0 && c->quant != Q_LOSSLESS &&
                          (c->zscale.present || c->has_zscale_kw);
    if (src == 1 && raw && c->zbitpix < 0 && !quantized)
        isfloat = 1;
    if (isfloat && rawsize != 4 && rawsize != 8)
        return -1;

    if (isfloat) {
        double sc = c->bscale, zo = c->bzero - ref;
        int plain = sc == 1.0 && zo == 0.0;
        for (int64_t i = 0; i < npix; i++) {
            double d;
            if (rawsize == 4) {
                uint32_t u = fq_be32(raw + 4 * i);
                float x;
                memcpy(&x, &u, 4);
                d = x;
            } else {
                uint64_t u = fq_be64(raw + 8 * i);
                memcpy(&d, &u, 8);
            }
            out[i] = plain ? (float)d : (float)(d * sc + zo);
        }
        return 0;
    }

    /* Integers: gather into ibuf when they are still raw. */
    if (!ints) {
        if (rawsize == 8) {
            /* 64 bit integers are rare; convert directly. */
            double sc = c->bscale, zo = c->bzero - ref;
            for (int64_t i = 0; i < npix; i++) {
                int64_t iv = (int64_t)fq_be64(raw + 8 * i);
                out[i] = (c->has_zblank && iv == c->zblank) ? NAN : (float)((double)iv * sc + zo);
            }
            return 0;
        }
        for (int64_t i = 0; i < npix; i++) {
            if (rawsize == 1)
                s->ibuf[i] = raw[i];
            else if (rawsize == 2)
                s->ibuf[i] = (int16_t)fq_be16(raw + 2 * i);
            else
                s->ibuf[i] = (int32_t)fq_be32(raw + 4 * i);
        }
    }

    int has_zb = c->has_zblank;
    int64_t zb = c->zblank;
    if (c->zblankc.present) {
        has_zb = 1;
        zb = col_int(row, &c->zblankc);
    }
    const int32_t *iv = s->ibuf;
    if (quantized) {
        double zs = c->zscale.present ? col_double(row, &c->zscale) : c->zscale_kw;
        double zz = c->zzero.present ? col_double(row, &c->zzero) : c->zzero_kw;
        zz -= ref;
        if (c->quant == Q_NODITHER) {
            for (int64_t i = 0; i < npix; i++)
                out[i] = (has_zb && iv[i] == zb) ? NAN : (float)(iv[i] * zs + zz);
            return 0;
        }
        pthread_once(&g_rand_once, init_rand);
        int64_t iseed = ((t + c->zdither0 - 1) % N_RANDOM + N_RANDOM) % N_RANDOM;
        int next = (int)(g_rand[iseed] * 500);
        for (int64_t i = 0; i < npix; i++) {
            if (has_zb && iv[i] == zb)
                out[i] = NAN;
            else if (c->quant == Q_SD2 && iv[i] == -2147483646)
                out[i] = (float)(-ref);
            else
                out[i] = (float)(((double)iv[i] - g_rand[next] + 0.5) * zs + zz);
            if (++next == N_RANDOM) {
                if (++iseed == N_RANDOM)
                    iseed = 0;
                next = (int)(g_rand[iseed] * 500);
            }
        }
        return 0;
    }
    double sc = c->bscale, zo = c->bzero - ref;
    if (c->zbitpix <= 16 && !has_zb) {
        /* Exact in single precision. */
        const float fs = (float)sc, fz = (float)zo;
        for (int64_t i = 0; i < npix; i++)
            out[i] = (float)iv[i] * fs + fz;
        return 0;
    }
    for (int64_t i = 0; i < npix; i++)
        out[i] = (has_zb && iv[i] == zb) ? NAN : (float)(iv[i] * sc + zo);
    return 0;
}

/* --------------------------------------------------- image description */

typedef struct {
    int hdu;
    int compressed, supported;
    int bitpix, naxis;
    int64_t naxes[FQ_MAXAXES];
    char cmptype[24];
} imgdesc;

/* Does HDU idx hold an image? Fills d if so. */
static int describe_image(fq_file *f, int idx, imgdesc *d)
{
    hdu_t *h = get_hdu(f, idx);
    if (!h)
        return 0;
    memset(d, 0, sizeof *d);
    d->hdu = idx;
    int is_img = idx == 0 || !strcmp(h->xtension, "IMAGE") || !strcmp(h->xtension, "IUEIMAGE");
    if (is_img && !h->groups) {
        if (h->naxis < 1)
            return 0;
        for (int i = 0; i < h->naxis && i < FQ_MAXAXES; i++)
            if (h->naxes[i] < 1)
                return 0;
        if (h->naxis > FQ_MAXAXES)
            return 0;
        d->bitpix = h->bitpix;
        d->naxis = h->naxis;
        memcpy(d->naxes, h->naxes, sizeof d->naxes);
        d->supported = 1;
        return 1;
    }
    if (!strcmp(h->xtension, "BINTABLE") && h->zimage) {
        comp_t c;
        d->compressed = 1;
        int rc = parse_comp(f, h, &c, d->cmptype, sizeof d->cmptype);
        h = get_hdu(f, idx);
        if (rc != 0)
            return 0;
        d->bitpix = c.zbitpix;
        d->naxis = c.znaxis;
        memcpy(d->naxes, c.znaxes, sizeof d->naxes);
        int64_t zn;
        if (kw_int(f, h, "ZNAXIS", &zn) && zn == 1)
            d->naxis = 1;
        d->supported = c.algo != ALG_UNSUPPORTED;
        return 1;
    }
    return 0;
}

static int select_image(fq_file *f, const fq_opts *o, imgdesc *d, char *err, size_t errlen)
{
    if (o->hdu >= 0) {
        if (!get_hdu(f, o->hdu)) {
            seterr(err, errlen, "there is no HDU %d", o->hdu);
            return -1;
        }
        if (!describe_image(f, o->hdu, d)) {
            seterr(err, errlen, "HDU %d holds no image", o->hdu);
            return -1;
        }
        if (!d->supported) {
            seterr(err, errlen, "%s compression is not supported", d->cmptype);
            return -1;
        }
        return 0;
    }
    imgdesc oned, unsup;
    memset(&oned, 0, sizeof oned);
    memset(&unsup, 0, sizeof unsup);
    int have1d = 0, haveunsup = 0;
    for (int i = 0; i < 4096; i++) {
        if (!get_hdu(f, i))
            break;
        imgdesc t;
        if (!describe_image(f, i, &t))
            continue;
        if (!t.supported) {
            if (!haveunsup) {
                unsup = t;
                haveunsup = 1;
            }
            continue;
        }
        int64_t W = t.naxes[0], H = t.naxis > 1 ? t.naxes[1] : 1;
        if (W >= 2 && H >= 2) {
            *d = t;
            return 0;
        }
        if (!have1d && W >= 2) {
            oned = t;
            have1d = 1;
        }
    }
    if (have1d) {
        *d = oned;
        return 0;
    }
    if (haveunsup) {
        seterr(err, errlen, "%s compression is not supported", unsup.cmptype);
        return -1;
    }
    seterr(err, errlen, "no image data");
    return -1;
}

/* ------------------------------------------------------- pixel access */

enum { F_U8, F_I16, F_I32, F_I64, F_F32, F_F64, F_F32N };

typedef struct {
    int fmt, bpp;
    double scale, zero, ref;
    int has_blank;
    int64_t blank;
    int64_t W, H;
    const uint8_t *base;   /* uncompressed: start of the data unit */
    int64_t avail;         /* bytes available from base */
    int64_t plane[3];      /* cube plane for each slot */
    float **rows;          /* compressed: decoded rows, [slot * H + y] */
} src_t;

static inline const uint8_t *src_row(const src_t *s, int slot, int64_t y)
{
    if (y < 0 || y >= s->H)
        return NULL;
    if (s->rows)
        return (const uint8_t *)s->rows[(int64_t)slot * s->H + y];
    int64_t rb = s->W * s->bpp;
    int64_t off = (s->plane[slot] * s->H + y) * rb;
    if (off + rb > s->avail)
        return NULL;
    return s->base + off;
}

/* Convert n pixels at indices IDX (an expression of x0, i, step) to floats. */
#define DECODE_FN(NAME, IDX)                                                     \
static void NAME(const src_t *s, const uint8_t *row, int64_t x0, int64_t step,  \
                 int64_t n, float *out)                                          \
{                                                                                \
    (void)step;                                                                  \
    const uint8_t *p = row;                                                      \
    const double dsc = s->scale, dzo = s->zero - s->ref;                         \
    const float fsc = (float)dsc, fzo = (float)dzo;                              \
    const int hb = s->has_blank;                                                 \
    const int64_t bl = s->blank;                                                 \
    switch (s->fmt) {                                                            \
    case F_U8:                                                                   \
        for (int64_t i = 0; i < n; i++) {                                        \
            uint8_t v = p[IDX];                                                  \
            out[i] = (hb && v == bl) ? NAN : v * fsc + fzo;                      \
        }                                                                        \
        break;                                                                   \
    case F_I16:                                                                  \
        if (hb) {                                                                \
            for (int64_t i = 0; i < n; i++) {                                    \
                int16_t v = (int16_t)fq_be16(p + 2 * (IDX));                     \
                out[i] = v == bl ? NAN : v * fsc + fzo;                          \
            }                                                                    \
        } else {                                                                 \
            for (int64_t i = 0; i < n; i++)                                      \
                out[i] = (int16_t)fq_be16(p + 2 * (IDX)) * fsc + fzo;            \
        }                                                                        \
        break;                                                                   \
    case F_I32:                                                                  \
        for (int64_t i = 0; i < n; i++) {                                        \
            int32_t v = (int32_t)fq_be32(p + 4 * (IDX));                         \
            out[i] = (hb && v == bl) ? NAN : (float)(v * dsc + dzo);             \
        }                                                                        \
        break;                                                                   \
    case F_I64:                                                                  \
        for (int64_t i = 0; i < n; i++) {                                        \
            int64_t v = (int64_t)fq_be64(p + 8 * (IDX));                         \
            out[i] = (hb && v == bl) ? NAN : (float)((double)v * dsc + dzo);     \
        }                                                                        \
        break;                                                                   \
    case F_F32:                                                                  \
        if (dsc == 1.0 && dzo == 0.0) {                                          \
            for (int64_t i = 0; i < n; i++) {                                    \
                uint32_t u = fq_be32(p + 4 * (IDX));                             \
                float v;                                                         \
                memcpy(&v, &u, 4);                                               \
                out[i] = v;                                                      \
            }                                                                    \
        } else {                                                                 \
            for (int64_t i = 0; i < n; i++) {                                    \
                uint32_t u = fq_be32(p + 4 * (IDX));                             \
                float v;                                                         \
                memcpy(&v, &u, 4);                                               \
                out[i] = (float)(v * dsc + dzo);                                 \
            }                                                                    \
        }                                                                        \
        break;                                                                   \
    case F_F64:                                                                  \
        for (int64_t i = 0; i < n; i++) {                                        \
            uint64_t u = fq_be64(p + 8 * (IDX));                                 \
            double v;                                                            \
            memcpy(&v, &u, 8);                                                   \
            out[i] = (float)(v * dsc + dzo);                                     \
        }                                                                        \
        break;                                                                   \
    case F_F32N: {                                                               \
        const float *q = (const float *)(const void *)p;                         \
        for (int64_t i = 0; i < n; i++)                                          \
            out[i] = q[IDX];                                                     \
        break;                                                                   \
    }                                                                            \
    }                                                                            \
}

DECODE_FN(decode_run, x0 + i)
DECODE_FN(decode_step, x0 + i * step)

/* ----------------------------------------------------------- the plan */

typedef struct {
    imgdesc d;
    int kind, color, nch, flip;
    char bayer[8];
    int map[2][2];            /* Bayer: channel for [y & 1][x & 1] */
    int64_t W, H, nplanes, plane;
    int64_t cw, ch;           /* cells: pixels, or 2x2 Bayer cells */
    int f, k, offs[MAX_K];
    int w, h;
    int truncated;
    src_t src;
    float **bands;            /* compressed: allocated band buffers */
    int64_t nbands_alloc;
} plan_t;

static void plan_free(plan_t *P)
{
    if (P->bands) {
        for (int64_t i = 0; i < P->nbands_alloc; i++)
            free(P->bands[i]);
        free(P->bands);
    }
    free(P->src.rows);
    P->bands = NULL;
    P->src.rows = NULL;
}

static int bayer_channel(char c)
{
    switch (toupper((unsigned char)c)) {
    case 'R': return 0;
    case 'G': return 1;
    case 'B': return 2;
    }
    return -1;
}

typedef struct {
    const comp_t *c;
    plan_t *P;
    int64_t band_h, nbands;
    int64_t *jobs;            /* slot * nbands + band */
    double ref;
    int failed_tiles;
} bandjob;

static void band_task(void *ctx, size_t ji)
{
    bandjob *J = ctx;
    const comp_t *c = J->c;
    plan_t *P = J->P;
    int64_t job = J->jobs[ji];
    int slot = (int)(job / J->nbands);
    int64_t b = job % J->nbands;
    int64_t W = P->W, y0 = b * J->band_h;
    int64_t bh = J->band_h;
    if (y0 + bh > P->H)
        bh = P->H - y0;

    /* Position of the cube plane inside the tile grid. */
    int64_t plane = P->src.plane[slot], rem = plane;
    int64_t tbase = 0, mult = c->ntile[0] * c->ntile[1];
    int64_t sub = 0, smult = 1;
    for (int a = 2; a < c->znaxis; a++) {
        int64_t z = rem % c->znaxes[a];
        rem /= c->znaxes[a];
        int64_t tz = z / c->ztile[a], oz = z % c->ztile[a];
        int64_t td = c->ztile[a];
        if ((tz + 1) * td > c->znaxes[a])
            td = c->znaxes[a] - tz * c->ztile[a];
        tbase += tz * mult;
        mult *= c->ntile[a];
        sub += oz * smult;
        smult *= td;
    }

    float *band = malloc((size_t)(W * bh) * sizeof(float));
    tscratch s;
    s.ibuf = malloc((size_t)c->maxtile * sizeof(int32_t));
    s.bbuf = malloc((size_t)c->maxtile * 16);
    float *tile = malloc((size_t)c->maxtile * sizeof(float));
    if (!band || !s.ibuf || !s.bbuf || !tile) {
        free(band);
        band = NULL;
        goto out;
    }
    for (int64_t tx = 0; tx < c->ntile[0]; tx++) {
        int64_t x0 = tx * c->ztile[0];
        int64_t tw = c->ztile[0];
        if (x0 + tw > W)
            tw = W - x0;
        int64_t t = tx + c->ntile[0] * b + tbase;
        int64_t npix = tw * bh * smult;
        int ok = decode_tile(c, t, npix, tile, &s, J->ref) == 0;
        if (!ok)
            __atomic_fetch_add(&J->failed_tiles, 1, __ATOMIC_RELAXED);
        const float *src = tile + sub * tw * bh;
        for (int64_t y = 0; y < bh; y++) {
            float *dst = band + y * W + x0;
            if (ok)
                memcpy(dst, src + y * tw, (size_t)tw * sizeof(float));
            else
                for (int64_t x = 0; x < tw; x++)
                    dst[x] = NAN;
        }
    }
    for (int64_t y = 0; y < bh; y++)
        P->src.rows[(int64_t)slot * P->H + y0 + y] = band + y * W;
out:
    P->bands[job] = band;
    free(s.ibuf);
    free(s.bbuf);
    free(tile);
}

/* Rows of the source plane that binning (or the spectrum) will read. */
static uint8_t *needed_rows(const plan_t *P)
{
    uint8_t *need = calloc((size_t)P->H, 1);
    if (!need)
        return NULL;
    if (P->kind == FQ_KIND_SPECTRUM) {
        need[0] = 1;
        return need;
    }
    for (int oy = 0; oy < P->h; oy++)
        for (int j = 0; j < P->k; j++) {
            int64_t cy = (int64_t)oy * P->f + P->offs[j];
            if (P->color == FQ_COLOR_BAYER) {
                for (int dy = 0; dy < 2; dy++)
                    if (2 * cy + dy < P->H)
                        need[2 * cy + dy] = 1;
            } else if (cy < P->H) {
                need[cy] = 1;
            }
        }
    return need;
}

static int load_compressed(fq_file *f, plan_t *P, int threads, char *err, size_t errlen)
{
    hdu_t *h = get_hdu(f, P->d.hdu);
    int64_t end = add_sat(h->data_off, h->data_len);
    need(f, end);
    h = get_hdu(f, P->d.hdu);
    comp_t c;
    char cmp[24];
    if (parse_comp(f, h, &c, cmp, sizeof cmp) != 0) {
        seterr(err, errlen, "cannot read the compressed image table");
        return -1;
    }
    c.tab = f->data + h->data_off;
    c.avail = f->size - h->data_off;
    if (c.avail > h->data_len)
        c.avail = h->data_len;
    if (c.avail < h->data_len)
        P->truncated = 1;

    int nslots = P->color == FQ_COLOR_RGB ? 3 : 1;
    int64_t band_h = c.ztile[1];
    int64_t nbands = c.ntile[1];
    P->src.rows = calloc((size_t)(P->H * nslots), sizeof(float *));
    P->nbands_alloc = nbands * nslots;
    P->bands = calloc((size_t)P->nbands_alloc, sizeof(float *));
    int64_t *jobs = malloc((size_t)P->nbands_alloc * sizeof(int64_t));
    uint8_t *need_r = needed_rows(P);
    if (!P->src.rows || !P->bands || !jobs || !need_r) {
        free(jobs);
        free(need_r);
        seterr(err, errlen, "out of memory");
        return -1;
    }
    int64_t njobs = 0;
    for (int slot = 0; slot < nslots; slot++)
        for (int64_t b = 0; b < nbands; b++) {
            int any = 0;
            for (int64_t y = b * band_h; y < (b + 1) * band_h && y < P->H && !any; y++)
                any = need_r[y];
            if (any)
                jobs[njobs++] = slot * nbands + b;
        }
    free(need_r);
    bandjob J = { &c, P, band_h, nbands, jobs, P->src.ref, 0 };
    par_for((size_t)njobs, threads, &J, band_task);
    free(jobs);
    if (J.failed_tiles)
        P->truncated = 1;
    return 0;
}

static int plan_image(fq_file *f, const fq_opts *o, plan_t *P, int force_image,
                      char *err, size_t errlen)
{
    hdu_t *h = get_hdu(f, P->d.hdu);
    const imgdesc *d = &P->d;
    char v[CARD];
    int64_t iv;

    P->W = d->naxes[0];
    P->H = d->naxis >= 2 ? d->naxes[1] : 1;
    P->nplanes = 1;
    for (int a = 2; a < d->naxis; a++)
        P->nplanes = mul_sat(P->nplanes, d->naxes[a]);
    P->kind = (P->H == 1 || (P->H <= 8 && P->W >= 64 * P->H)) ? FQ_KIND_SPECTRUM : FQ_KIND_IMAGE;
    if (force_image)
        P->kind = FQ_KIND_IMAGE;

    /* Colour: three plane cubes and Bayer mosaics. */
    P->color = FQ_COLOR_MONO;
    if (!o->mono && P->kind == FQ_KIND_IMAGE) {
        if (d->naxis == 3 && d->naxes[2] == 3) {
            int rgb = 1;
            if (kw_str(f, h, "CTYPE3", v, sizeof v) && v[0]) {
                for (char *p = v; *p; p++)
                    *p = (char)toupper((unsigned char)*p);
                rgb = strstr(v, "RGB") || strstr(v, "COLO");
            }
            if (rgb && o->plane < 0)
                P->color = FQ_COLOR_RGB;
        }
        if (P->color == FQ_COLOR_MONO && P->nplanes == 1 && P->W >= 2 && P->H >= 2 &&
            (kw_str(f, h, "BAYERPAT", v, sizeof v) || kw_str(f, h, "COLORTYP", v, sizeof v))) {
            int ok = strlen(v) == 4;
            for (int i = 0; ok && i < 4; i++)
                ok = bayer_channel(v[i]) >= 0;
            if (ok) {
                P->color = FQ_COLOR_BAYER;
                for (int i = 0; i < 4; i++)
                    P->bayer[i] = (char)toupper((unsigned char)v[i]);
                P->bayer[4] = 0;
            }
        }
    }
    int topdown = kw_str(f, h, "ROWORDER", v, sizeof v) && !strcasecmp(v, "TOP-DOWN");
    int bottomup = !topdown && kw_str(f, h, "ROWORDER", v, sizeof v) && !strcasecmp(v, "BOTTOM-UP");
    P->flip = !topdown;
    if (P->color == FQ_COLOR_BAYER) {
        int64_t xo = 0, yo = 0;
        if (kw_int(f, h, "XBAYROFF", &iv)) xo = iv;
        if (kw_int(f, h, "YBAYROFF", &iv)) yo = iv;
        /* The pattern starts at the first stored row unless the writer
           says it flipped the rows (ROWORDER = 'BOTTOM-UP'). */
        int yflip = bottomup ? (int)((P->H - 1) & 1) : 0;
        for (int py = 0; py < 2; py++)
            for (int px = 0; px < 2; px++) {
                int ry = (int)(((py ^ yflip) + yo) & 1);
                int rx = (int)((px + xo) & 1);
                P->map[py][px] = bayer_channel(P->bayer[ry * 2 + rx]);
            }
    }
    P->nch = P->color == FQ_COLOR_MONO ? 1 : 3;

    /* Planes. */
    if (o->plane >= 0)
        P->plane = o->plane < P->nplanes ? o->plane : P->nplanes - 1;
    else
        P->plane = d->naxis >= 3 ? d->naxes[2] / 2 : 0;
    if (P->color == FQ_COLOR_RGB)
        P->plane = 0;
    for (int s = 0; s < 3; s++)
        P->src.plane[s] = P->color == FQ_COLOR_RGB ? s : P->plane;

    /* Geometry. */
    if (P->color == FQ_COLOR_BAYER) {
        P->cw = P->W / 2;
        P->ch = P->H / 2;
    } else {
        P->cw = P->W;
        P->ch = P->H;
    }
    int mw = o->max_width > 0 ? o->max_width : 1024;
    int mh = o->max_height > 0 ? o->max_height : 1024;
    int64_t f1 = (P->cw + mw - 1) / mw, f2 = (P->ch + mh - 1) / mh;
    int64_t fb = f1 > f2 ? f1 : f2;
    if (fb < 1)
        fb = 1;
    if (fb > INT_MAX / 4)
        fb = INT_MAX / 4;
    P->f = (int)fb;
    int64_t w = P->cw / fb, hh = P->ch / fb;
    P->w = (int)(w < 1 ? 1 : w);
    P->h = (int)(hh < 1 ? 1 : hh);
    int k = o->max_samples <= 0 ? P->f : (o->max_samples < P->f ? o->max_samples : P->f);
    if (k > MAX_K)
        k = MAX_K;
    if (k < 1)
        k = 1;
    P->k = k;
    for (int i = 0; i < k; i++)
        P->offs[i] = (int)(((2 * (int64_t)i + 1) * P->f) / (2 * k));

    /* Source. */
    src_t *s = &P->src;
    s->W = P->W;
    s->H = P->H;
    s->scale = h->bscale;
    s->zero = h->bzero;
    s->has_blank = h->has_blank && h->bitpix > 0;
    s->blank = h->blank;
    if (d->compressed) {
        s->fmt = F_F32N;
        s->bpp = 4;
        s->scale = 1;
        s->zero = 0;
        s->has_blank = 0;
        return load_compressed(f, P, o->threads, err, errlen);
    }
    switch (h->bitpix) {
    case 8: s->fmt = F_U8; s->bpp = 1; break;
    case 16: s->fmt = F_I16; s->bpp = 2; break;
    case 32: s->fmt = F_I32; s->bpp = 4; break;
    case 64: s->fmt = F_I64; s->bpp = 8; break;
    case -32: s->fmt = F_F32; s->bpp = 4; break;
    default: s->fmt = F_F64; s->bpp = 8; break;
    }
    int64_t end = add_sat(h->data_off, h->data_len);
    need(f, end);
    h = get_hdu(f, P->d.hdu);
    s->base = f->data + h->data_off;
    s->avail = f->size - h->data_off;
    if (s->avail > h->data_len)
        s->avail = h->data_len;
    if (s->avail < h->data_len)
        P->truncated = 1;
    if (s->avail < 0)
        s->avail = 0;

    /* Wide integer and double data can carry a large offset that float32
       cannot resolve; measure values relative to a pixel near the centre. */
    s->ref = 0;
    if (!o->exact && (s->fmt == F_I32 || s->fmt == F_I64 || s->fmt == F_F64)) {
        const uint8_t *r = src_row(s, 0, P->H / 2);
        if (r) {
            float pv;
            decode_run(s, r, P->W / 2, 1, 1, &pv);
            if (is_finite(pv) && fabsf(pv) > 1e5f)
                s->ref = pv;
        }
    }
#if defined(POSIX_MADV_WILLNEED)
    if (P->k == P->f && f->map && f->maplen && !f->z) {
        /* Everything will be read: ask for read-ahead. */
        uintptr_t a = (uintptr_t)s->base & ~(uintptr_t)4095;
        uintptr_t e = (uintptr_t)(s->base + s->avail);
        if (e > a)
            posix_madvise((void *)a, (size_t)(e - a), POSIX_MADV_WILLNEED);
    }
#endif
    return 0;
}

/* -------------------------------------------------------------- binning */

typedef struct {
    const plan_t *P;
    float *out;          /* nch planes of w * h */
    int nchunks;
    int *nan_flag;
    int oom;
} binjob;

/* Accumulate n values (already gathered per output column) into acc/cnt. */
static inline void accumulate(const float *v, float *acc, float *cnt, int n)
{
    for (int i = 0; i < n; i++) {
        float x = v[i];
        int ok = is_finite(x);
        acc[i] += ok ? x : 0.0f;
        cnt[i] += ok ? 1.0f : 0.0f;
    }
}

static void bin_plane_row(const plan_t *P, int slot, int oy, float *tmp, float *col,
                          float *acc, float *cnt)
{
    const src_t *s = &P->src;
    const int w = P->w, f = P->f;
    memset(acc, 0, (size_t)w * sizeof(float));
    memset(cnt, 0, (size_t)w * sizeof(float));
    if (P->k == f) {
        /* Every pixel: sum the block's rows column by column, then add
           up the columns of each block once. */
        int64_t n = (int64_t)w * f;
        if (n > P->W)
            n = P->W;
        float *csum = col, *ccnt = col + n;
        if (f > 1) {
            memset(csum, 0, (size_t)n * sizeof(float));
            memset(ccnt, 0, (size_t)n * sizeof(float));
        }
        int any = 0;
        for (int j = 0; j < f; j++) {
            const uint8_t *row = src_row(s, slot, (int64_t)oy * f + j);
            if (!row)
                continue;
            decode_run(s, row, 0, 1, n, tmp);
            accumulate(tmp, f > 1 ? csum : acc, f > 1 ? ccnt : cnt, (int)n);
            any = 1;
        }
        if (f == 1 || !any)
            return;
        for (int ox = 0; ox < w; ox++) {
            int64_t b0 = (int64_t)ox * f, b1 = b0 + f;
            if (b1 > n)
                b1 = n;
            float a = 0, c = 0;
            for (int64_t x = b0; x < b1; x++) {
                a += csum[x];
                c += ccnt[x];
            }
            acc[ox] = a;
            cnt[ox] = c;
        }
        return;
    }
    for (int j = 0; j < P->k; j++) {
        const uint8_t *row = src_row(s, slot, (int64_t)oy * f + P->offs[j]);
        if (!row)
            continue;
        for (int i = 0; i < P->k; i++) {
            int64_t x0 = P->offs[i];
            if (x0 >= P->W)
                continue;
            int64_t n = (P->W - 1 - x0) / f + 1;
            if (n > w)
                n = w;
            decode_step(s, row, x0, f, n, tmp);
            accumulate(tmp, acc, cnt, (int)n);
        }
    }
}

static void bin_bayer_row(const plan_t *P, int oy, float *tmp, float *col, float *acc, float *cnt)
{
    const src_t *s = &P->src;
    const int w = P->w, f = P->f;
    memset(acc, 0, 3 * (size_t)w * sizeof(float));
    memset(cnt, 0, 3 * (size_t)w * sizeof(float));
    if (P->k == f) {
        /* Column sums kept apart for even and odd rows, since the colour of
           a pixel depends on both parities. */
        int64_t n = 2 * (int64_t)w * f;
        if (n > P->W)
            n = P->W;
        float *csum = col, *ccnt = col + 2 * n;
        memset(col, 0, 4 * (size_t)n * sizeof(float));
        for (int j = 0; j < f; j++)
            for (int dy = 0; dy < 2; dy++) {
                int64_t y = 2 * ((int64_t)oy * f + j) + dy;
                const uint8_t *row = src_row(s, 0, y);
                if (!row)
                    continue;
                decode_run(s, row, 0, 1, n, tmp);
                accumulate(tmp, csum + (y & 1) * n, ccnt + (y & 1) * n, (int)n);
            }
        for (int ox = 0; ox < w; ox++) {
            int64_t b0 = 2 * (int64_t)ox * f, b1 = b0 + 2 * f;
            if (b1 > n)
                b1 = n;
            for (int64_t x = b0; x < b1; x++)
                for (int py = 0; py < 2; py++) {
                    int c = P->map[py][x & 1];
                    acc[c * w + ox] += csum[py * n + x];
                    cnt[c * w + ox] += ccnt[py * n + x];
                }
        }
        return;
    }
    for (int j = 0; j < P->k; j++) {
        int64_t cy = (int64_t)oy * f + P->offs[j];
        for (int dy = 0; dy < 2; dy++) {
            int64_t y = 2 * cy + dy;
            const uint8_t *row = src_row(s, 0, y);
            if (!row)
                continue;
            const int *map = P->map[y & 1];
            for (int i = 0; i < P->k; i++)
                for (int dx = 0; dx < 2; dx++) {
                    int64_t x0 = 2 * (int64_t)P->offs[i] + dx;
                    if (x0 >= P->W)
                        continue;
                    int64_t n = (P->W - 1 - x0) / (2 * f) + 1;
                    if (n > w)
                        n = w;
                    decode_step(s, row, x0, 2 * f, n, tmp);
                    int c = map[x0 & 1];
                    accumulate(tmp, acc + c * w, cnt + c * w, (int)n);
                }
        }
    }
}

static void bin_task(void *ctx, size_t ci)
{
    binjob *J = ctx;
    const plan_t *P = J->P;
    int oy0 = (int)((int64_t)P->h * (int64_t)ci / J->nchunks);
    int oy1 = (int)((int64_t)P->h * (int64_t)(ci + 1) / J->nchunks);
    if (oy0 >= oy1)
        return;
    const int w = P->w;
    int64_t tmpn = P->W > w ? P->W : w;
    float *tmp = malloc((size_t)tmpn * sizeof(float));
    float *col = malloc(4 * (size_t)tmpn * sizeof(float));
    float *acc = malloc(3 * (size_t)w * sizeof(float));
    float *cnt = malloc(3 * (size_t)w * sizeof(float));
    int hasnan = 0;
    if (!tmp || !col || !acc || !cnt) {
        J->oom = 1;
        goto done;
    }
    const size_t plane = (size_t)w * P->h;
    for (int oy = oy0; oy < oy1; oy++) {
        if (P->color == FQ_COLOR_BAYER) {
            bin_bayer_row(P, oy, tmp, col, acc, cnt);
        }
        for (int c = 0; c < P->nch; c++) {
            if (P->color != FQ_COLOR_BAYER)
                bin_plane_row(P, c, oy, tmp, col, acc, cnt);
            const float *a = P->color == FQ_COLOR_BAYER ? acc + c * w : acc;
            const float *n = P->color == FQ_COLOR_BAYER ? cnt + c * w : cnt;
            float *o = J->out + c * plane + (size_t)oy * w;
            for (int ox = 0; ox < w; ox++) {
                if (n[ox] > 0) {
                    o[ox] = a[ox] / n[ox];
                } else {
                    o[ox] = NAN;
                    hasnan = 1;
                }
            }
        }
    }
    J->nan_flag[ci] = hasnan;
done:
    free(tmp);
    free(col);
    free(acc);
    free(cnt);
}

/* Bin the plan's source into nch float planes. */
static float *bin_image(const plan_t *P, int threads, int *has_nan)
{
    size_t plane = (size_t)P->w * P->h;
    float *out = malloc(plane * P->nch * sizeof(float));
    int nchunks = P->h < 256 ? P->h : 256;
    int *flags = calloc((size_t)nchunks, sizeof(int));
    if (!out || !flags) {
        free(out);
        free(flags);
        return NULL;
    }
    binjob J = { P, out, nchunks, flags, 0 };
    par_for((size_t)nchunks, threads, &J, bin_task);
    *has_nan = 0;
    for (int i = 0; i < nchunks; i++)
        *has_nan |= flags[i];
    free(flags);
    if (J.oom) {
        free(out);
        return NULL;
    }
    return out;
}

/* ----------------------------------------------------------- statistics */

/* k-th smallest of a[0..n) (reorders a). All values must be finite. */
static float select_kth(float *a, int64_t n, int64_t k)
{
    int64_t lo = 0, hi = n - 1;
    while (hi > lo) {
        int64_t mid = lo + (hi - lo) / 2;
        float x = a[lo], y = a[mid], z = a[hi];
        float pv = x < y ? (y < z ? y : (x < z ? z : x)) : (x < z ? x : (y < z ? z : y));
        int64_t i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pv)
                i++;
            while (a[j] > pv)
                j--;
            if (i <= j) {
                float t = a[i];
                a[i] = a[j];
                a[j] = t;
                i++;
                j--;
            }
        }
        if (k <= j)
            hi = j;
        else if (k >= i)
            lo = i;
        else
            return a[k];
    }
    return a[k];
}

static float percentile(float *a, int64_t n, double p)
{
    int64_t k = (int64_t)(p * (double)(n - 1) + 0.5);
    if (k < 0) k = 0;
    if (k >= n) k = n - 1;
    return select_kth(a, n, k);
}

/* Finite samples of one plane on a regular grid, at most about maxn. */
static int64_t gather(const float *pl, int w, int h, float *buf, int64_t maxn)
{
    double total = (double)w * h;
    int step = (int)ceil(sqrt(total / (double)maxn));
    if (step < 1)
        step = 1;
    int64_t n = 0;
    for (int y = step / 2; y < h; y += step)
        for (int x = step / 2; x < w; x += step) {
            float v = pl[(size_t)y * w + x];
            if (is_finite(v))
                buf[n++] = v;
        }
    if (n < 1000 && step > 1) {   /* mostly empty image: take everything */
        n = 0;
        for (size_t i = 0; i < (size_t)w * h && n < maxn; i++)
            if (is_finite(pl[i]))
                buf[n++] = pl[i];
    }
    return n;
}

typedef struct {
    int valid;
    float c0, inv, m;            /* t = (v - c0) * inv, out = mtf(m, t) */
    double med, sig, lo, hi;
} stretch_t;

/* Build the display stretch from samples (reorders v; d is scratch). */
static void make_stretch(float *v, float *d, int64_t n, int mode, stretch_t *st)
{
    memset(st, 0, sizeof *st);
    st->m = 0.5f;
    if (n <= 0)
        return;
    st->valid = 1;
    float vmin = v[0], vmax = v[0];
    for (int64_t i = 1; i < n; i++) {
        if (v[i] < vmin) vmin = v[i];
        if (v[i] > vmax) vmax = v[i];
    }
    double lo, hi, m = 0.5;
    double med = 0, sig = 0;
    if (!(vmax > vmin)) {
        st->c0 = vmin - 1.0f;
        st->inv = 0.5f;
        st->med = vmin;
        st->lo = vmin;
        st->hi = vmax;
        return;
    }
    if (mode == FQ_STRETCH_MINMAX) {
        lo = vmin;
        hi = vmax;
        med = percentile(v, n, 0.5);
    } else if (mode == FQ_STRETCH_LINEAR) {
        lo = percentile(v, n, 0.005);
        hi = percentile(v, n, 0.995);
        med = percentile(v, n, 0.5);
        if (!(hi > lo)) {
            lo = vmin;
            hi = vmax;
        }
    } else {
        int64_t nn = n;
        float fmed = select_kth(v, nn, nn / 2);
        for (int64_t i = 0; i < nn; i++)
            d[i] = fabsf(v[i] - fmed);
        float mad = select_kth(d, nn, nn / 2);
        if (!(mad > 0)) {
            /* More than half the samples share one value (padding, masks,
               quiet integer data). Describe the rest of the image. */
            int64_t m2 = 0;
            for (int64_t i = 0; i < nn; i++)
                if (v[i] != fmed)
                    v[m2++] = v[i];
            if (m2 >= 16) {
                nn = m2;
                fmed = select_kth(v, nn, nn / 2);
                for (int64_t i = 0; i < nn; i++)
                    d[i] = fabsf(v[i] - fmed);
                mad = select_kth(d, nn, nn / 2);
            }
        }
        med = fmed;
        sig = 1.4826 * mad;
        if (mad > 0) {
            lo = med - 2.8 * sig;
            if (lo < vmin)
                lo = vmin;
            hi = vmax;
            double x0 = (med - lo) / (hi - lo);
            /* Midtones balance putting the median at 25% grey; never darken. */
            m = x0 >= 0.25 ? 0.5 : 3.0 * x0 / (2.0 * x0 + 1.0);
            if (m < 1e-12)
                m = 1e-12;
        } else {
            lo = vmin;
            hi = vmax;
        }
    }
    st->med = med;
    st->sig = sig;
    st->lo = lo;
    st->hi = hi;
    st->c0 = (float)lo;
    st->inv = (float)(1.0 / (hi - lo));
    if (!is_finite(st->inv) || st->inv == 0) {
        st->c0 = (float)lo - 1.0f;
        st->inv = 0.5f;
    }
    st->m = (float)m;
}

/* ------------------------------------------------------------- mapping */

typedef struct {
    const plan_t *P;
    const float *bin;
    const stretch_t *st;
    uint8_t *px;
    size_t row_bytes;
    int comps, nchunks;
} mapjob;

static inline uint8_t stretch_byte(const stretch_t *st, float v)
{
    float t = (v - st->c0) * st->inv;
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    float m = st->m;
    float y = ((m - 1.0f) * t) / ((2.0f * m - 1.0f) * t - m);
    return (uint8_t)(y * 255.0f + 0.5f);
}

static void map_task(void *ctx, size_t ci)
{
    mapjob *J = ctx;
    const plan_t *P = J->P;
    const int w = P->w, h = P->h;
    int r0 = (int)((int64_t)h * (int64_t)ci / J->nchunks);
    int r1 = (int)((int64_t)h * (int64_t)(ci + 1) / J->nchunks);
    const size_t plane = (size_t)w * h;
    for (int r = r0; r < r1; r++) {
        int sy = P->flip ? h - 1 - r : r;
        uint8_t *o = J->px + (size_t)r * J->row_bytes;
        const float *b0 = J->bin + (size_t)sy * w;
        if (J->comps == 1) {
            const stretch_t st = J->st[0];
            for (int x = 0; x < w; x++)
                o[x] = stretch_byte(&st, b0[x]);
        } else if (P->nch == 1) {
            const stretch_t st = J->st[0];
            for (int x = 0; x < w; x++) {
                float v = b0[x];
                if (is_finite(v)) {
                    uint8_t g = stretch_byte(&st, v);
                    o[4 * x] = o[4 * x + 1] = o[4 * x + 2] = g;
                    o[4 * x + 3] = 255;
                } else {
                    o[4 * x] = o[4 * x + 1] = o[4 * x + 2] = o[4 * x + 3] = 0;
                }
            }
        } else {
            const float *b1 = b0 + plane, *b2 = b0 + 2 * plane;
            for (int x = 0; x < w; x++) {
                float r_ = b0[x], g_ = b1[x], bl = b2[x];
                if (is_finite(r_) && is_finite(g_) && is_finite(bl)) {
                    o[4 * x] = stretch_byte(&J->st[0], r_);
                    o[4 * x + 1] = stretch_byte(&J->st[1], g_);
                    o[4 * x + 2] = stretch_byte(&J->st[2], bl);
                    o[4 * x + 3] = 255;
                } else {
                    o[4 * x] = o[4 * x + 1] = o[4 * x + 2] = o[4 * x + 3] = 0;
                }
            }
        }
    }
}

/* ------------------------------------------------------------- spectra */

static int render_spectrum(fq_file *f, const fq_opts *o, plan_t *P, fq_image *img)
{
    const src_t *s = &P->src;
    const int64_t W = P->W;
    const uint8_t *row = src_row(s, 0, 0);
    float *v = malloc((size_t)W * sizeof(float));
    if (!v)
        return -1;
    if (row) {
        decode_run(s, row, 0, 1, W, v);
    } else {
        for (int64_t i = 0; i < W; i++)
            v[i] = NAN;
    }
    int ncol = o->max_width > 0 ? o->max_width : 1024;
    if (ncol > W)
        ncol = (int)W;
    img->spec_n = ncol;
    img->spec_points = W;
    img->spec_lo = malloc((size_t)ncol * sizeof(float));
    img->spec_hi = malloc((size_t)ncol * sizeof(float));
    float *samp = malloc((size_t)(W < STAT_SAMPLES ? W : STAT_SAMPLES) * sizeof(float));
    if (!img->spec_lo || !img->spec_hi || !samp) {
        free(v);
        free(samp);
        return -1;
    }
    double ref = s->ref;
    for (int c = 0; c < ncol; c++) {
        int64_t i0 = W * c / ncol, i1 = W * (c + 1) / ncol;
        float lo = NAN, hi = NAN;
        for (int64_t i = i0; i < i1; i++) {
            float x = v[i];
            if (!is_finite(x))
                continue;
            if (!(x >= lo)) lo = x;
            if (!(x <= hi)) hi = x;
        }
        img->spec_lo[c] = lo + (float)ref;
        img->spec_hi[c] = hi + (float)ref;
    }
    int64_t step = W / STAT_SAMPLES + 1, n = 0;
    for (int64_t i = 0; i < W; i += step)
        if (is_finite(v[i]))
            samp[n++] = v[i];
    if (n > 0) {
        float mn = samp[0], mx = samp[0];
        for (int64_t i = 1; i < n; i++) {
            if (samp[i] < mn) mn = samp[i];
            if (samp[i] > mx) mx = samp[i];
        }
        double lo = mn, hi = mx;
        float p0 = percentile(samp, n, 0.001), p1 = percentile(samp, n, 0.999);
        if ((double)p1 - p0 < 0.2 * ((double)mx - mn)) {   /* a few wild points */
            lo = p0;
            hi = p1;
        }
        double pad = (hi - lo) * 0.05;
        if (!(pad > 0))
            pad = fabs(hi) > 0 ? fabs(hi) * 0.1 : 1.0;
        img->y_min = lo - pad + ref;
        img->y_max = hi + pad + ref;
        if (!isfinite(img->y_min) || !isfinite(img->y_max) || !(img->y_max > img->y_min)) {
            img->y_min = lo;
            img->y_max = hi > lo ? hi : lo + 1;
        }
        if (!isfinite(img->y_min) || !isfinite(img->y_max) || !(img->y_max > img->y_min)) {
            img->y_min = -1;
            img->y_max = 1;
        }
    } else {
        img->y_min = -1;
        img->y_max = 1;
    }
    free(samp);
    free(v);

    hdu_t *h = get_hdu(f, P->d.hdu);
    double crval, cdelt, crpix = 1;
    char buf[CARD];
    if (kw_dbl(f, h, "CRVAL1", &crval) &&
        (kw_dbl(f, h, "CDELT1", &cdelt) || kw_dbl(f, h, "CD1_1", &cdelt))) {
        kw_dbl(f, h, "CRPIX1", &crpix);
        img->has_x = 1;
        img->x_first = crval + (1.0 - crpix) * cdelt;
        img->x_last = crval + ((double)W - crpix) * cdelt;
        int64_t dcflag;
        if ((kw_str(f, h, "CTYPE1", buf, sizeof buf) && strstr(buf, "LOG")) ||
            (kw_int(f, h, "DC-FLAG", &dcflag) && dcflag == 1))
            img->x_log = 1;
        if (kw_str(f, h, "CUNIT1", buf, sizeof buf))
            scopy(img->x_unit, sizeof img->x_unit, buf);
    }
    if (kw_str(f, h, "BUNIT", buf, sizeof buf))
        scopy(img->y_unit, sizeof img->y_unit, buf);
    return 0;
}

/* ---------------------------------------------------------- public API */

void fq_opts_default(fq_opts *o)
{
    memset(o, 0, sizeof *o);
    o->max_width = 1024;
    o->max_height = 1024;
    o->max_samples = 4;
    o->stretch = FQ_STRETCH_AUTO;
    o->hdu = -1;
    o->plane = -1;
}

static void fill_info(fq_file *f, const plan_t *P, fq_info *in)
{
    memset(in, 0, sizeof *in);
    hdu_t *h = get_hdu(f, P->d.hdu);
    in->kind = P->kind;
    in->hdu = P->d.hdu;
    if (h)
        scopy(in->extname, sizeof in->extname, h->extname);
    in->bitpix = P->d.bitpix;
    in->naxis = P->d.naxis;
    memcpy(in->naxes, P->d.naxes, sizeof in->naxes);
    in->compressed = P->d.compressed;
    scopy(in->cmptype, sizeof in->cmptype, P->d.cmptype);
    in->plane = P->plane;
    in->nplanes = P->nplanes;
    in->color = P->color;
    scopy(in->bayer, sizeof in->bayer, P->bayer);
    in->bin = P->color == FQ_COLOR_BAYER ? 2 * P->f : P->f;
    in->samples = P->k;
    in->width = P->w;
    in->height = P->h;
    in->flipped = P->flip;
    in->truncated = P->truncated;
}

static int prepare(fq_file *f, const fq_opts *o, plan_t *P, int force_image,
                   char *err, size_t errlen)
{
    memset(P, 0, sizeof *P);
    if (select_image(f, o, &P->d, err, errlen) != 0)
        return -1;
    if (plan_image(f, o, P, force_image, err, errlen) != 0) {
        plan_free(P);
        return -1;
    }
    return 0;
}

float *fq_decode_float(fq_file *f, const fq_opts *opts, int *w, int *h, int *nch,
                       fq_info *info, char *err, size_t errlen)
{
    fq_opts o;
    if (opts)
        o = *opts;
    else
        fq_opts_default(&o);
    plan_t P;
    if (prepare(f, &o, &P, 1, err, errlen) != 0)
        return NULL;
    int has_nan = 0;
    float *out = bin_image(&P, o.threads, &has_nan);
    if (!out)
        seterr(err, errlen, "out of memory");
    else if (P.src.ref != 0) {
        size_t n = (size_t)P.w * P.h * P.nch;
        for (size_t i = 0; i < n; i++)
            out[i] = (float)(out[i] + P.src.ref);
    }
    if (info)
        fill_info(f, &P, info);
    *w = P.w;
    *h = P.h;
    *nch = P.nch;
    plan_free(&P);
    return out;
}

fq_image *fq_render(fq_file *f, const fq_opts *opts, char *err, size_t errlen)
{
    fq_opts o;
    if (opts)
        o = *opts;
    else
        fq_opts_default(&o);
    plan_t P;
    if (prepare(f, &o, &P, 0, err, errlen) != 0)
        return NULL;
    fq_image *img = calloc(1, sizeof *img);
    if (!img) {
        plan_free(&P);
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    fill_info(f, &P, &img->info);

    if (P.kind == FQ_KIND_SPECTRUM) {
        if (render_spectrum(f, &o, &P, img) != 0) {
            plan_free(&P);
            fq_image_free(img);
            seterr(err, errlen, "out of memory");
            return NULL;
        }
        plan_free(&P);
        return img;
    }

    int has_nan = 0;
    float *bin = bin_image(&P, o.threads, &has_nan);
    if (!bin) {
        plan_free(&P);
        fq_image_free(img);
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    plan_free(&P);

    /* Stretch per channel. */
    stretch_t st[3];
    size_t plane = (size_t)P.w * P.h;
    int64_t cap = STAT_SAMPLES + P.w + P.h + 16;
    float *sv = malloc((size_t)cap * sizeof(float));
    float *sd = malloc((size_t)cap * sizeof(float));
    if (!sv || !sd) {
        free(sv);
        free(sd);
        free(bin);
        fq_image_free(img);
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    int any_valid = 0;
    for (int c = 0; c < P.nch; c++) {
        int64_t n = gather(bin + c * plane, P.w, P.h, sv, STAT_SAMPLES);
        make_stretch(sv, sd, n, o.stretch, &st[c]);
        any_valid |= st[c].valid;
    }
    free(sv);
    free(sd);
    double ref = P.src.ref;
    img->info.median = st[0].med + ref;
    img->info.sigma = st[0].sig;
    img->info.black = st[0].lo + ref;
    img->info.white = st[0].hi + ref;
    if (!any_valid)
        has_nan = 1;

    img->width = P.w;
    img->height = P.h;
    img->components = (P.nch == 1 && !has_nan) ? 1 : 4;
    img->row_bytes = (size_t)P.w * img->components;
    img->pixels = malloc(img->row_bytes * P.h);
    if (!img->pixels) {
        free(bin);
        fq_image_free(img);
        seterr(err, errlen, "out of memory");
        return NULL;
    }
    int nchunks = P.h < 128 ? P.h : 128;
    mapjob M = { &P, bin, st, img->pixels, img->row_bytes, img->components, nchunks };
    par_for((size_t)nchunks, o.threads, &M, map_task);
    free(bin);
    return img;
}

void fq_image_free(fq_image *img)
{
    if (!img)
        return;
    free(img->pixels);
    free(img->spec_lo);
    free(img->spec_hi);
    free(img);
}

/* ------------------------------------------------------- header text */

char *fq_header_text(fq_file *f, int idx, size_t *len)
{
    hdu_t *h = get_hdu(f, idx);
    if (!h)
        return NULL;
    int64_t n = h->hdr_len / CARD;
    char *out = malloc((size_t)n * (CARD + 1) + 1);
    if (!out)
        return NULL;
    const char *p = (const char *)f->data + h->hdr_off;
    size_t o = 0;
    for (int64_t i = 0; i < n; i++) {
        const char *c = p + i * CARD;
        int e = CARD;
        while (e > 0 && c[e - 1] == ' ')
            e--;
        for (int j = 0; j < e; j++) {
            unsigned char ch = (unsigned char)c[j];
            out[o++] = (ch >= 32 && ch < 127) ? (char)ch : '?';
        }
        out[o++] = '\n';
        if (key_is(c, "END"))
            break;
    }
    out[o] = 0;
    if (len)
        *len = o;
    return out;
}

static const char *type_name(int bitpix, double bscale, double bzero)
{
    switch (bitpix) {
    case 8: return bzero == -128 && bscale == 1 ? "int8" : "uint8";
    case 16: return bzero == 32768 && bscale == 1 ? "uint16" : "int16";
    case 32: return bzero == 2147483648.0 && bscale == 1 ? "uint32" : "int32";
    case 64: return "int64";
    case -32: return "float32";
    case -64: return "float64";
    }
    return "?";
}

static void dims_text(char *b, size_t n, int naxis, const int64_t *ax)
{
    size_t o = 0;
    b[0] = 0;
    for (int i = 0; i < naxis && i < FQ_MAXAXES && o + 24 < n; i++)
        o += (size_t)snprintf(b + o, n - o, i ? " x %lld" : "%lld", (long long)ax[i]);
}

char *fq_summary_text(fq_file *f)
{
    int n = fq_hdu_count(f);
    size_t cap = (size_t)n * 128 + 64, o = 0;
    char *out = malloc(cap);
    if (!out)
        return NULL;
    out[0] = 0;
    for (int i = 0; i < n; i++) {
        hdu_t h = f->hdu[i];
        char dims[96], desc[160];
        const char *name = h.extname[0] ? h.extname : (i == 0 ? "PRIMARY" : "");
        const char *type = i == 0 ? "IMAGE" : h.xtension;
        imgdesc d;
        if (h.zimage && describe_image(f, i, &d)) {
            dims_text(dims, sizeof dims, d.naxis, d.naxes);
            hdu_t *hp = get_hdu(f, i);
            snprintf(desc, sizeof desc, "%s  %s  (%s)", dims,
                     type_name(d.bitpix, hp->bscale, hp->bzero), d.cmptype);
            type = "COMPRESSED";
        } else if (!strcmp(h.xtension, "BINTABLE") || !strcmp(h.xtension, "TABLE")) {
            int64_t tf = 0;
            kw_int(f, &f->hdu[i], "TFIELDS", &tf);
            snprintf(desc, sizeof desc, "%lld columns x %lld rows", (long long)tf,
                     (long long)(h.naxis >= 2 ? h.naxes[1] : 0));
        } else if (h.naxis == 0 || h.data_len == 0) {
            snprintf(desc, sizeof desc, "no data");
        } else {
            dims_text(dims, sizeof dims, h.naxis, h.naxes);
            snprintf(desc, sizeof desc, "%s  %s", dims, type_name(h.bitpix, h.bscale, h.bzero));
        }
        int k = snprintf(out + o, cap - o, "%3d  %-12s %-10s %s\n", i, name, type, desc);
        if (k < 0 || (size_t)k >= cap - o)
            break;
        o += (size_t)k;
    }
    return out;
}
