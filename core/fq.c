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
    if (f->size < CARD || memcmp(f->data, "SIMPLE  =", 9) != 0) {
        fq_close(f);
        fqi_seterr(err, errlen, "not a FITS file");
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
    if (st.st_size < CARD) {
        close(fd);
        fqi_seterr(err, errlen, "file too small to be FITS");
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
    if (!data || size < CARD) {
        fqi_seterr(err, errlen, "buffer too small to be FITS");
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

/* ------------------------------------------------------- header text */

char *fq_header_text(fq_file *f, int idx, size_t *len)
{
    hdu_t *h = fqi_get_hdu(f, idx);
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
            snprintf(desc, sizeof desc, "%lld columns x %lld rows", (long long)tf,
                     (long long)(h.naxis >= 2 ? h.naxes[1] : 0));
        } else if (h.naxis == 0 || h.data_len == 0) {
            snprintf(desc, sizeof desc, "no data");
        } else {
            fqi_dims_text(dims, sizeof dims, h.naxis, h.naxes);
            snprintf(desc, sizeof desc, "%s  %s", dims, fqi_type_name(h.bitpix, h.bscale, h.bzero));
        }
        int k = snprintf(out + o, cap - o, "%3d  %-12s %-10s %s\n", i, name, type, desc);
        if (k < 0 || (size_t)k >= cap - o)
            break;
        o += (size_t)k;
    }
    return out;
}
