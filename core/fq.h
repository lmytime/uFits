/*
 * fq.h - uFits core: a small, fast FITS reader and preview renderer.
 *
 * Portable C99. The only dependency is zlib. Nothing here knows about
 * macOS; the Quick Look extensions and the command line tool are thin
 * wrappers around these calls.
 *
 * Speed comes from never reading more of the file than the output needs:
 * the file is memory mapped, images are binned straight from the mapping
 * (sampling a few pixels per output pixel when shrinking a lot), only the
 * tiles that cover sampled rows are decompressed, and all heavy loops run
 * on every core.
 */
#ifndef FQ_H
#define FQ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FQ_MAXAXES 9

typedef struct fq_file fq_file;

enum { FQ_KIND_NONE = 0, FQ_KIND_IMAGE = 1, FQ_KIND_PLOT = 2 };
enum { FQ_COLOR_MONO = 0, FQ_COLOR_RGB = 1, FQ_COLOR_BAYER = 2 };
enum {
    FQ_STRETCH_AUTO = 0,   /* robust midtone stretch (median/MAD based) */
    FQ_STRETCH_LINEAR = 1, /* linear between the 0.5 and 99.5 percentiles */
    FQ_STRETCH_MINMAX = 2  /* linear between the minimum and maximum */
};

typedef struct {
    int max_width, max_height; /* output box in pixels */
    int max_samples;   /* samples per axis per output pixel when shrinking;
                          0 = average every source pixel */
    int stretch;       /* FQ_STRETCH_* */
    int hdu;           /* -1 = first HDU with image data */
    int plane;         /* -1 = automatic (middle plane of a cube) */
    int mono;          /* 1 = ignore Bayer / RGB colour hints */
    int threads;       /* 0 = all cores, 1 = single threaded */
    int exact;         /* 1 = keep absolute values in fq_decode_float */
} fq_opts;

void fq_opts_default(fq_opts *o);

typedef struct {
    int kind;                 /* FQ_KIND_* */
    int hdu;                  /* HDU that was rendered (0 = primary) */
    char extname[72];
    int bitpix;               /* BITPIX, or ZBITPIX for compressed images */
    int naxis;
    int64_t naxes[FQ_MAXAXES];
    int compressed;
    char cmptype[24];
    int64_t plane, nplanes;   /* plane shown, number of planes in the cube */
    int color;                /* FQ_COLOR_* */
    char bayer[8];
    int bin;                  /* source pixels per output pixel (per axis) */
    int samples;              /* samples per axis per output pixel */
    int width, height;        /* output size in pixels */
    int flipped;              /* 1 = first FITS row is at the bottom */
    int truncated;            /* file ends before the data does */
    int empty;                /* no finite pixel values at all */
    int table;                /* plot of two columns of a binary table;
                                 naxes[0] is then the number of rows */
    double median, sigma;     /* channel 0 statistics in data units */
    double black, white;      /* display range of channel 0 */
} fq_info;

typedef struct {
    fq_info info;

    /* FQ_KIND_IMAGE: 8 bit pixels, top row first. components is 1 (gray)
       or 4 (RGBA, premultiplied; fully transparent where data is NaN). */
    int width, height, components;
    size_t row_bytes;
    uint8_t *pixels;

    /* FQ_KIND_PLOT (spectra, light curves): min/max envelope of the values
       per output column; columns are evenly spaced from x_first to x_last. */
    int spec_n;
    float *spec_lo, *spec_hi;
    int64_t spec_points;       /* number of samples plotted */
    double y_min, y_max;       /* suggested plot range */
    int has_x;                 /* x axis from WCS keywords or a column */
    double x_first, x_last;    /* x of the first and last column */
    int x_log;                 /* x values are log10 of the wavelength */
    char x_unit[24], y_unit[24];
    char x_label[32], y_label[32]; /* axis names: table columns or CTYPE1 */
    int y_flip;                /* magnitudes: smaller values belong on top */
    int points;                /* a time series: draw points, not a line */
} fq_image;

/* Open a FITS file (plain or gzip compressed). Returns NULL on failure and
   writes a message to err. */
fq_file *fq_open(const char *path, char *err, size_t errlen);
/* Same for a buffer in memory. With copy == 0 the buffer must outlive the
   fq_file. */
fq_file *fq_open_memory(const void *data, size_t size, int copy,
                        char *err, size_t errlen);
void fq_close(fq_file *f);

/* Render the first image (or opts->hdu) for display. */
fq_image *fq_render(fq_file *f, const fq_opts *opts, char *err, size_t errlen);
void fq_image_free(fq_image *img);

/* Binned values before stretching, nch planes of w*h floats, FITS row
   order (first row = bottom row). For tests and tools. Free with free(). */
float *fq_decode_float(fq_file *f, const fq_opts *opts, int *w, int *h,
                       int *nch, fq_info *info, char *err, size_t errlen);

/* Number of HDUs (reads every header in the file). */
int fq_hdu_count(fq_file *f);

typedef struct {
    int hdu;
    int kind;                 /* FQ_KIND_IMAGE or FQ_KIND_PLOT */
    int64_t nplanes;          /* planes of a cube */
    char extname[72];
    char desc[96];            /* "4096 x 4096 float32", "PDCSAP_FLUX vs TIME" */
} fq_hdu_entry;

/* The HDUs uFits can show, in file order; returns how many (at most max). */
int fq_list_hdus(fq_file *f, fq_hdu_entry *out, int max);
/* Columns and first rows of a table HDU as text. malloc'd, NULL if the HDU
   is not a table. */
char *fq_table_text(fq_file *f, int hdu, int maxrows, size_t *len);
/* Header cards of one HDU, one per line. malloc'd, NULL if no such HDU. */
char *fq_header_text(fq_file *f, int hdu, size_t *len);
/* One line per HDU describing its contents. malloc'd. */
char *fq_summary_text(fq_file *f);
/* Value of a keyword (strings unquoted). Returns 1 if found. */
int fq_keyword(fq_file *f, int hdu, const char *key, char *val, size_t vallen);

#ifdef __cplusplus
}
#endif
#endif
