/*
 * fq_internal.h - types and helpers shared by the core's source files:
 * fq.c (files, headers), fq_image.c (images), fq_table.c (tables) and
 * fq_codec.c (decompression).
 */
#ifndef FQ_INTERNAL_H
#define FQ_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <zlib.h>

#include "fq.h"

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#error "uFits assumes a little-endian host"
#endif

#define CARD 80
#define BLOCK 2880
#define BIG ((int64_t)1 << 62)
#define STAT_SAMPLES 200000

static inline uint16_t fq_be16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return __builtin_bswap16(v); }
static inline uint32_t fq_be32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return __builtin_bswap32(v); }
static inline uint64_t fq_be64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return __builtin_bswap64(v); }

static inline int fqi_finite(float v) { return (v - v) == 0.0f; }

/* One HDU, as far as the core needs to know it. */
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

/* An HDU holding an image (plain or tile compressed). */
typedef struct {
    int hdu;
    int compressed, supported;
    int bitpix, naxis;
    int64_t naxes[FQ_MAXAXES];
    char cmptype[24];
} imgdesc;

/* A binary table with columns worth plotting. */
typedef struct {
    int xcol, ycol;            /* column indexes */
    int xlog;                  /* x holds log10 values (loglam) */
    int yflip;                 /* y is a magnitude: brighter is up */
    int points;                /* a time series: draw points, not a line */
    int64_t nrows, repeat;     /* rows, values per row and column */
    char xname[32], yname[32];
} fqi_plotspec;

/* fq.c */
void fqi_seterr(char *err, size_t n, const char *fmt, ...);
void fqi_scopy(char *dst, size_t n, const char *src);
int64_t fqi_mul_sat(int64_t a, int64_t b);
int64_t fqi_add_sat(int64_t a, int64_t b);
int64_t fqi_need(fq_file *f, int64_t end);
hdu_t *fqi_get_hdu(fq_file *f, int idx);
int fqi_kw_str(const fq_file *f, const hdu_t *h, const char *key, char *out, size_t n);
int fqi_kw_int(const fq_file *f, const hdu_t *h, const char *key, int64_t *v);
int fqi_kw_dbl(const fq_file *f, const hdu_t *h, const char *key, double *v);
int64_t fqi_elem_size(char t);
int64_t fqi_parse_tform(const char *s, int64_t *repeat, char *type, char *desc);
const char *fqi_type_name(int bitpix, double bscale, double bzero);
/* Value of a header card: strings unquoted, other values as their token,
   anything but printable ASCII as '?'. 1 = string, 0 = other, -1 = none. */
int fqi_card_value(const char *card, char *out, size_t outlen);
void fqi_dims_text(char *b, size_t n, int naxis, const int64_t *ax);

/* fq_image.c */
int fqi_describe_image(fq_file *f, int idx, imgdesc *d);
float fqi_percentile(float *a, int64_t n, double p);
void fqi_plot_range(float *samp, int64_t n, double *ymin, double *ymax);

/* fq_table.c */
int fqi_table_plot_spec(fq_file *f, int idx, fqi_plotspec *ps);
int fqi_table_plot(fq_file *f, int idx, const fq_opts *o, fq_image *img, char *err, size_t errlen);

/* fq_codec.c */

/* Rice decoding as used by FITS tiled image compression (RICE_1).
   Produces npix values; bytepix is 1, 2 or 4. Returns 0 on success. */
int fq_rice_decode(const uint8_t *in, size_t inlen, int32_t *out, int64_t npix,
                   int blocksize, int bytepix);

/* IRAF PLIO line list (16 bit words in host order) to npix pixels. */
int fq_plio_decode(const int16_t *ll, size_t nwords, int32_t *out, int64_t npix);

/* Inflate a gzip or zlib stream into out. Returns the number of bytes
   written, or -1 on error. */
int64_t fq_inflate(const uint8_t *in, size_t inlen, uint8_t *out, size_t outcap);

/* Undo the GZIP_2 byte shuffle. */
void fq_unshuffle(const uint8_t *in, uint8_t *out, int64_t n, int itemsize);

#endif
