/*
 * fq.c - uFits core: files, headers and keywords.
 *
 * Opens a file (memory mapped, or inflated on demand when gzipped), walks
 * the HDU headers lazily and answers keyword lookups. Images are rendered
 * in fq_image.c, tables in fq_table.c.
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
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define MAX_HDUS 100000
#define GZ_LIMIT ((int64_t)1 << 30)     /* never inflate more than 1 GiB */

/* ------------------------------------------------------------ utilities */

void fqi_sb_add(fqi_sbuf *b, const char *s, size_t n)
{
    if (b->oom)
        return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 4096;
        while (cap < b->len + n + 1)
            cap *= 2;
        char *p = realloc(b->s, cap);
        if (!p) {
            b->oom = 1;
            return;
        }
        b->s = p;
        b->cap = cap;
    }
    memcpy(b->s + b->len, s, n);
    b->len += n;
    b->s[b->len] = 0;
}

void fqi_sb_printf(fqi_sbuf *b, const char *fmt, ...)
{
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n > 0)
        fqi_sb_add(b, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
}

void fqi_seterr(char *err, size_t n, const char *fmt, ...)
{
    if (!err || !n)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, n, fmt, ap);
    va_end(ap);
}

int64_t fqi_mul_sat(int64_t a, int64_t b)
{
    if (a < 0 || b < 0)
        return BIG;
    if (a == 0 || b == 0)
        return 0;
    if (a > BIG / b)
        return BIG;
    return a * b;
}

int64_t fqi_add_sat(int64_t a, int64_t b)
{
    if (a >= BIG || b >= BIG || a > BIG - b)
        return BIG;
    return a + b;
}

/* Bounded string copy that always terminates. */
void fqi_scopy(char *dst, size_t n, const char *src)
{
    size_t i = 0;
    for (; src[i] && i + 1 < n; i++)
        dst[i] = src[i];
    dst[i] = 0;
}


/* ------------------------------------------------------------- the file */

/* Make bytes [0, end) available when the file is being inflated lazily.
   Returns the number of bytes available. Invalidates pointers into data. */
int64_t fqi_need(fq_file *f, int64_t end)
{
    if (!f->z || f->gz_done || end <= f->size)
        return f->size;
    int64_t want = fqi_add_sat(end, (int64_t)1 << 20);
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
            fqi_seterr(err, errlen, "cannot start gzip decompression");
            return NULL;
        }
        f->gzsrc = bytes;
        f->gzlen = len;
        f->data = NULL;
        f->size = 0;
        fqi_need(f, BLOCK);
    } else {
        f->data = bytes;
        f->size = (int64_t)len;
    }
    if (f->size >= 8 && !memcmp(f->data, "XISF0100", 8)) {
        if (fqi_xisf_open(f, err, errlen) == 0)
            return f;
        fq_close(f);
        return NULL;
    }
    if (f->size < CARD || memcmp(f->data, "SIMPLE  =", 9) != 0) {
        fq_close(f);
        fqi_seterr(err, errlen, "not a FITS or XISF file");
        return NULL;
    }
    return f;
}

fq_file *fq_open(const char *path, char *err, size_t errlen)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fqi_seterr(err, errlen, "cannot open file: %s", strerror(errno));
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        fqi_seterr(err, errlen, "not a regular file");
        return NULL;
    }
    if (st.st_size < 16) {
        close(fd);
        fqi_seterr(err, errlen, "file too small to be FITS or XISF");
        return NULL;
    }
    size_t len = (size_t)st.st_size;
    void *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) {
        fqi_seterr(err, errlen, "cannot map file: %s", strerror(errno));
        return NULL;
    }
    fq_file *f = calloc(1, sizeof *f);
    if (!f) {
        munmap(m, len);
        fqi_seterr(err, errlen, "out of memory");
        return NULL;
    }
    f->map = m;
    f->maplen = len;
    return finish_open(f, m, len, err, errlen);
}

fq_file *fq_open_memory(const void *data, size_t size, int copy, char *err, size_t errlen)
{
    if (!data || size < 16 || size > INT64_MAX) {
        fqi_seterr(err, errlen, "invalid FITS or XISF buffer size");
        return NULL;
    }
    fq_file *f = calloc(1, sizeof *f);
    if (!f) {
        fqi_seterr(err, errlen, "out of memory");
        return NULL;
    }
    const uint8_t *bytes = data;
    if (copy) {
        uint8_t *p = malloc(size);
        if (!p) {
            free(f);
            fqi_seterr(err, errlen, "out of memory");
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
    for (int i = 0; i < f->nhdu; i++)
        fqi_xisf_free(f->hdu[i].xisf);
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
int fqi_card_value(const char *c, char *out, size_t outlen)
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
    if (fqi_need(f, off + BLOCK) < off + BLOCK)
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
        if (fqi_need(f, pos + BLOCK) < pos + BLOCK)
            return -1;
        const char *blk = (const char *)f->data + pos;
        for (int i = 0; i < 36 && !ended; i++) {
            const char *c = blk + i * CARD;
            switch (c[0]) {
            case 'E':
                if (key_is(c, "END"))
                    ended = 1;
                else if (key_is(c, "EXTNAME") && fqi_card_value(c, v, sizeof v) >= 0)
                    fqi_scopy(h->extname, sizeof h->extname, v);
                break;
            case 'X':
                if (key_is(c, "XTENSION") && fqi_card_value(c, v, sizeof v) >= 0) {
                    size_t k = 0;
                    for (; v[k] && k + 1 < sizeof h->xtension; k++)
                        h->xtension[k] = (char)toupper((unsigned char)v[k]);
                    h->xtension[k] = 0;
                }
                break;
            case 'B':
                if (key_is(c, "BITPIX")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                        h->bitpix = (int)iv;
                } else if (key_is(c, "BSCALE")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0 && parse_dbl(v, &dv) && dv != 0)
                        h->bscale = dv;
                } else if (key_is(c, "BZERO")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0 && parse_dbl(v, &dv))
                        h->bzero = dv;
                } else if (key_is(c, "BLANK")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv)) {
                        h->has_blank = 1;
                        h->blank = iv;
                    }
                }
                break;
            case 'N':
                if (memcmp(c, "NAXIS", 5) == 0 && fqi_card_value(c, v, sizeof v) >= 0 &&
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
                            extra = fqi_mul_sat(extra, iv);
                    }
                }
                break;
            case 'P':
                if (key_is(c, "PCOUNT") && fqi_card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                    h->pcount = iv;
                break;
            case 'G':
                if (key_is(c, "GCOUNT")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0 && parse_int(v, &iv))
                        h->gcount = iv;
                } else if (key_is(c, "GROUPS")) {
                    if (fqi_card_value(c, v, sizeof v) >= 0)
                        h->groups = v[0] == 'T';
                }
                break;
            case 'Z':
                if (key_is(c, "ZIMAGE") && fqi_card_value(c, v, sizeof v) >= 0)
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
            nelem = fqi_mul_sat(nelem, h->naxes[i]);
        nelem = fqi_mul_sat(nelem, extra);
        nelem = fqi_mul_sat(h->gcount, fqi_add_sat(h->pcount < 0 ? BIG : h->pcount, nelem));
    }
    int64_t bytes = fqi_mul_sat(nelem, (b < 0 ? -b : b) / 8);
    if (bytes >= BIG)
        return -1;
    h->data_len = bytes;
    h->next_off = fqi_add_sat(h->data_off, (bytes + BLOCK - 1) / BLOCK * BLOCK);
    return 0;
}

/* HDU idx, parsing headers as needed. The pointer is only valid until the
   next call. */
hdu_t *fqi_get_hdu(fq_file *f, int idx)
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
    fqi_get_hdu(f, MAX_HDUS);
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

int fqi_kw_str(const fq_file *f, const hdu_t *h, const char *key, char *out, size_t n)
{
    if (h->xisf)
        return fqi_xisf_keyword(h, key, out, n);
    const char *c = hdu_card(f, h, key);
    return c && fqi_card_value(c, out, n) >= 0;
}

int fqi_kw_int(const fq_file *f, const hdu_t *h, const char *key, int64_t *v)
{
    char b[CARD];
    return fqi_kw_str(f, h, key, b, sizeof b) && parse_int(b, v);
}

int fqi_kw_dbl(const fq_file *f, const hdu_t *h, const char *key, double *v)
{
    char b[CARD];
    return fqi_kw_str(f, h, key, b, sizeof b) && parse_dbl(b, v);
}

int fq_keyword(fq_file *f, int idx, const char *key, char *val, size_t vallen)
{
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h || !val || !vallen)
        return 0;
    return fqi_kw_str(f, h, key, val, vallen);
}

/* ------------------------------------------------------------ table forms */

int64_t fqi_elem_size(char t)
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
int64_t fqi_parse_tform(const char *s, int64_t *repeat, char *type, char *desc)
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
    *repeat = rep;
    if (t == 'P' || t == 'Q') {
        char e = (char)toupper((unsigned char)s[1]);
        *desc = t;
        *type = e ? e : 'B';
        return rep ? (t == 'P' ? 8 : 16) : 0;
    }
    if (t == 'X')
        return (rep + 7) / 8;
    int64_t es = fqi_elem_size(t);
    if (!es)
        return -1;
    return fqi_mul_sat(rep, es);
}

/* ------------------------------------------------------- header cards */

/* A card's value field from index i: a string (quotes removed, '' read as
   a quote, trailing blanks dropped) or a token, then the comment. */
typedef struct {
    int string;
    fqi_sbuf val, com;
} cardval;

static void add_printable(fqi_sbuf *b, const char *s, int n)
{
    for (int i = 0; i < n; i++) {
        char ch = printable(s[i]);
        fqi_sb_add(b, &ch, 1);
    }
}

static void card_value(const char *c, int i, cardval *v)
{
    while (i < CARD && c[i] == ' ')
        i++;
    if (i < CARD && c[i] == '\'') {
        v->string = 1;
        for (i++; i < CARD; i++) {
            if (c[i] == '\'') {
                if (i + 1 < CARD && c[i + 1] == '\'') {
                    fqi_sb_add(&v->val, "'", 1);
                    i++;
                    continue;
                }
                i++;
                break;
            }
            add_printable(&v->val, c + i, 1);
        }
        while (v->val.len && v->val.s[v->val.len - 1] == ' ')
            v->val.s[--v->val.len] = 0;
    } else {
        int j = i;
        while (j < CARD && c[j] != '/')
            j++;
        int k = j;
        while (k > i && c[k - 1] == ' ')
            k--;
        add_printable(&v->val, c + i, k - i);
        i = j;
    }
    while (i < CARD && c[i] != '/')
        i++;
    if (i++ < CARD) {
        while (i < CARD && c[i] == ' ')
            i++;
        int k = CARD;
        while (k > i && c[k - 1] == ' ')
            k--;
        add_printable(&v->com, c + i, k - i);
    }
}

static void cardval_free(cardval *v)
{
    free(v->val.s);
    free(v->com.s);
    memset(v, 0, sizeof *v);
}

/* One output line: kind, key, value, comment, separated by tabs (cards are
   printable ASCII, so they hold no tabs or newlines). */
static void card_line(fqi_sbuf *out, char kind, const char *key, const cardval *v)
{
    fqi_sb_add(out, &kind, 1);
    fqi_sb_add(out, "\t", 1);
    fqi_sb_add(out, key, strlen(key));
    fqi_sb_add(out, "\t", 1);
    if (v->string)
        fqi_sb_add(out, "'", 1);
    if (v->val.len)
        fqi_sb_add(out, v->val.s, v->val.len);
    if (v->string)
        fqi_sb_add(out, "'", 1);
    fqi_sb_add(out, "\t", 1);
    if (v->com.len)
        fqi_sb_add(out, v->com.s, v->com.len);
    fqi_sb_add(out, "\n", 1);
}

char *fq_header_cards(fq_file *f, int idx, size_t *len)
{
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h)
        return NULL;
    if (h->xisf)
        return fqi_xisf_cards(h, len);
    const char *p = (const char *)f->data + h->hdr_off;
    const int64_t n = h->hdr_len / CARD;
    fqi_sbuf out = { 0 };
    char key[CARD + 1];
    cardval v = { 0 };
    int pending = 0;   /* v holds a keyword's value, which CONTINUE cards may extend */
    for (int64_t i = 0; i < n; i++) {
        const char *c = p + i * CARD;
        if (pending && key_is(c, "CONTINUE") && v.string && v.val.len && v.val.s[v.val.len - 1] == '&') {
            cardval cv = { 0 };
            card_value(c, 8, &cv);
            if (cv.string) {   /* a long string goes on: join it */
                v.val.s[--v.val.len] = 0;
                if (cv.val.len)
                    fqi_sb_add(&v.val, cv.val.s, cv.val.len);
                if (cv.com.len) {
                    if (v.com.len)
                        fqi_sb_add(&v.com, " ", 1);
                    fqi_sb_add(&v.com, cv.com.s, cv.com.len);
                }
                cardval_free(&cv);
                continue;
            }
            cardval_free(&cv);
        }
        if (pending) {
            card_line(&out, 'v', key, &v);
            cardval_free(&v);
            pending = 0;
        }
        if (key_is(c, "END")) {
            fqi_sb_add(&out, "e\tEND\t\t\n", 8);
            break;
        }
        const char *eq = memcmp(c, "HIERARCH ", 9) == 0 ? memchr(c + 9, '=', CARD - 9) : NULL;
        if (eq || (c[8] == '=' && c[9] == ' ')) {
            int a = eq ? 9 : 0, b = eq ? (int)(eq - c) : 8, k = 0;
            if (eq) {
                memcpy(key, "HIERARCH ", 9);
                k = 9;
            }
            while (a < b && c[a] == ' ')
                a++;
            while (b > a && c[b - 1] == ' ')
                b--;
            for (; a < b; a++)
                key[k++] = printable(c[a]);
            key[k] = 0;
            card_value(c, eq ? (int)(eq - c) + 1 : 10, &v);
            pending = 1;
            continue;
        }
        /* Commentary: COMMENT, HISTORY, blank keyword or no value. */
        int k = 8;
        while (k > 0 && c[k - 1] == ' ')
            k--;
        for (int j = 0; j < k; j++)
            key[j] = printable(c[j]);
        key[k] = 0;
        cardval t = { 0 };
        int b = CARD;   /* the text keeps its indent */
        while (b > 8 && c[b - 1] == ' ')
            b--;
        add_printable(&t.com, c + 8, b - 8);
        card_line(&out, 'c', key, &t);
        cardval_free(&t);
    }
    if (pending)
        card_line(&out, 'v', key, &v);
    cardval_free(&v);
    if (out.oom) {
        free(out.s);
        return NULL;
    }
    if (!out.s)
        fqi_sb_add(&out, "", 0);
    if (len)
        *len = out.len;
    return out.s;
}

/* ----------------------------------------------------- header layout */

/* The four fields of one line of fq_header_cards. Returns the next line. */
typedef struct {
    const char *s[4];
    int n[4];
} cardfields;

static const char *card_fields(const char *line, cardfields *cf)
{
    const char *end = strchr(line, '\n');
    if (!end)
        end = line + strlen(line);
    const char *s = line;
    for (int i = 0; i < 4; i++) {
        const char *tab = i < 3 ? memchr(s, '\t', (size_t)(end - s)) : NULL;
        const char *e = tab ? tab : end;
        cf->s[i] = s;
        cf->n[i] = (int)(e - s);
        s = tab ? tab + 1 : e;
    }
    return *end ? end + 1 : end;
}

static void add_span(fqi_sbuf *spans, size_t start, size_t len, int kind)
{
    fq_span sp = { (uint32_t)start, (uint32_t)len, kind };
    if (len && start + len <= UINT32_MAX)
        fqi_sb_add(spans, (const char *)&sp, sizeof sp);
}

static void add_spaces(fqi_sbuf *b, int n)
{
    static const char blanks[] = "                                        ";
    for (; n > 0; n -= 40)
        fqi_sb_add(b, blanks, n < 40 ? (size_t)n : 40);
}

char *fq_header_layout(fq_file *f, int idx, size_t *len, fq_span **spans, size_t *nspans)
{
    if (spans)
        *spans = NULL;
    if (nspans)
        *nspans = 0;
    char *cards = fq_header_cards(f, idx, NULL);
    if (!cards)
        return NULL;
    /* Column widths: the longest key (at least the standard 8) and the
       longest value followed by a comment, leaving out very long ones,
       which would push all the others far to the right. */
    int kw = 8, vw = 0;
    cardfields cf;
    for (const char *l = cards; *l;) {
        l = card_fields(l, &cf);
        char kind = cf.s[0][0];
        if (kind != 'e' && cf.n[1] > kw && cf.n[1] <= 36)
            kw = cf.n[1];
        if (kind == 'v' && cf.n[3] && cf.n[2] > vw && cf.n[2] <= 30)
            vw = cf.n[2];
    }
    fqi_sbuf out = { 0 }, sp = { 0 };
    for (const char *l = cards; *l;) {
        l = card_fields(l, &cf);
        char kind = cf.s[0][0];
        add_span(&sp, out.len, (size_t)cf.n[1], FQ_SPAN_KEY);
        fqi_sb_add(&out, cf.s[1], (size_t)cf.n[1]);
        if (kind == 'v') {
            add_spaces(&out, kw - cf.n[1]);
            add_span(&sp, out.len, 3, FQ_SPAN_MARK);
            fqi_sb_add(&out, " = ", 3);
            fqi_sb_add(&out, cf.s[2], (size_t)cf.n[2]);
            if (cf.n[3]) {
                add_spaces(&out, vw - cf.n[2]);
                add_span(&sp, out.len, 3, FQ_SPAN_MARK);
                fqi_sb_add(&out, " / ", 3);
                add_span(&sp, out.len, (size_t)cf.n[3], FQ_SPAN_COMMENT);
                fqi_sb_add(&out, cf.s[3], (size_t)cf.n[3]);
            }
        } else if (kind == 'c' && cf.n[3]) {   /* COMMENT, HISTORY: text under the values */
            add_spaces(&out, kw - cf.n[1] + 3);
            add_span(&sp, out.len, (size_t)cf.n[3], FQ_SPAN_COMMENT);
            fqi_sb_add(&out, cf.s[3], (size_t)cf.n[3]);
        }
        fqi_sb_add(&out, "\n", 1);
    }
    free(cards);
    if (!out.s)
        fqi_sb_add(&out, "", 0);
    if (out.oom || sp.oom) {
        free(out.s);
        free(sp.s);
        return NULL;
    }
    if (len)
        *len = out.len;
    if (spans && nspans && sp.len) {
        *spans = (fq_span *)(void *)sp.s;
        *nspans = sp.len / sizeof(fq_span);
    } else {
        free(sp.s);
    }
    return out.s;
}

/* ------------------------------------------------------- header text */

char *fq_header_text(fq_file *f, int idx, size_t *len)
{
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h)
        return NULL;
    if (h->xisf)
        return fq_header_layout(f, idx, len, NULL, NULL);
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

const char *fqi_type_name(int bitpix, double bscale, double bzero)
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

void fqi_dims_text(char *b, size_t n, int naxis, const int64_t *ax)
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
        if (h.zimage && fqi_describe_image(f, i, &d)) {
            fqi_dims_text(dims, sizeof dims, d.naxis, d.naxes);
            hdu_t *hp = fqi_get_hdu(f, i);
            snprintf(desc, sizeof desc, "%s  %s  (%s)", dims,
                     fqi_type_name(d.bitpix, hp->bscale, hp->bzero), d.cmptype);
            type = "COMPRESSED";
        } else if (!strcmp(h.xtension, "BINTABLE") || !strcmp(h.xtension, "TABLE")) {
            int64_t tf = 0;
            fqi_kw_int(f, &f->hdu[i], "TFIELDS", &tf);
            long long rows = h.naxis >= 2 ? (long long)h.naxes[1] : 0;
            snprintf(desc, sizeof desc, "%lld row%s x %lld column%s", rows, rows == 1 ? "" : "s",
                     (long long)tf, tf == 1 ? "" : "s");
        } else if (h.naxis == 0 || h.data_len == 0) {
            snprintf(desc, sizeof desc, "no data");
        } else {
            fqi_dims_text(dims, sizeof dims, h.naxis, h.naxes);
            snprintf(desc, sizeof desc, "%s  %s", dims, h.xisf ? fqi_xisf_type(&h) :
                     fqi_type_name(h.bitpix, h.bscale, h.bzero));
            if (h.xisf)
                type = "XISF";
        }
        int k = snprintf(out + o, cap - o, "%3d  %-12s %-10s %s\n", i, name, type, desc);
        if (k < 0 || (size_t)k >= cap - o)
            break;
        o += (size_t)k;
    }
    return out;
}
