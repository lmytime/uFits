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

enum {
    FQ_KIND_NONE = 0,
    FQ_KIND_IMAGE = 1,
    FQ_KIND_PLOT = 2,  /* spectra, light curves, sky positions */
    FQ_KIND_TABLE = 3  /* fq_list_hdus only: a table with nothing to plot */
};
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
    int keep;          /* 1 = keep the binned values, for fq_restretch */
    int64_t region[4]; /* images: only this part, in pixels: x, y, width,
                          height, from the first pixel of the first row in
                          the file (all 0 = the whole image) */
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
    int64_t region[4];        /* images: the pixels shown, as in fq_opts
                                 (binning leaves out up to bin - 1 at the
                                 right and at the last rows) */
} fq_info;

/* How values became grey levels, per channel: t = (v - ref - c0) * inv
   clamped to [0, 1], then the midtones transfer function with m. */
typedef struct {
    int nch;
    float c0[3], inv[3], m[3];
    double ref;
} fq_stretch;

typedef struct fq_kept fq_kept;

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
    int x_flip;                /* x grows to the left (right ascension) */
    int x_wrap;                /* x is an angle shown modulo 360: the data
                                  straddle 0, so x runs from below 0 */
    char x_unit[24], y_unit[24];
    char x_label[32], y_label[32]; /* axis names: table columns or CTYPE1 */
    int y_flip;                /* magnitudes: smaller values belong on top */
    int points;                /* a time series: draw points, not a line */
    /* For points: how many points fall in each cell (at most 255) of a grid
       of spec_n columns by dot_rows rows, row 0 at y_min, column by column. */
    int dot_rows;
    uint8_t *dots;

    fq_stretch stretch;        /* FQ_KIND_IMAGE: for fq_render_detail */
    fq_kept *kept;             /* binned values (opts.keep), private */
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
/* Stretch an image rendered with opts.keep again, without reading the
   file: new pixels (the old ones are freed unless taken: set pixels to
   NULL to keep them) and display range. 0 on success. */
int fq_restretch(fq_image *img, int stretch, int threads);
/* Render the part opts->region of an image with more detail (to fit
   opts->max_width x max_height), mapped to grey levels with the stretch
   of a whole-image rendering of the same HDU and plane (its img->stretch),
   so that it can be laid over it. */
fq_image *fq_render_detail(fq_file *f, const fq_opts *opts, const fq_stretch *stretch,
                           char *err, size_t errlen);
void fq_image_free(fq_image *img);

/* Binned values before stretching, nch planes of w*h floats, FITS row
   order (first row = bottom row). For tests and tools. Free with free(). */
float *fq_decode_float(fq_file *f, const fq_opts *opts, int *w, int *h,
                       int *nch, fq_info *info, char *err, size_t errlen);

/* Number of HDUs (reads every header in the file). */
int fq_hdu_count(fq_file *f);

typedef struct {
    int hdu;
    int kind;                 /* FQ_KIND_IMAGE, FQ_KIND_PLOT or FQ_KIND_TABLE */
    int table;                /* a table (plotted or not): fq_table_open works */
    int64_t nplanes;          /* planes of a cube */
    char extname[72];
    char desc[96];            /* "4096 x 4096 float32", "PDCSAP_FLUX vs TIME",
                                 "120 rows x 8 columns" */
} fq_hdu_entry;

/* The HDUs uFits can show (images, plots) or list (tables), in file order;
   returns how many (at most max). */
int fq_list_hdus(fq_file *f, fq_hdu_entry *out, int max);
/* Columns and first rows of a table HDU as text. malloc'd, NULL if the HDU
   is not a table. */
char *fq_table_text(fq_file *f, int hdu, int maxrows, size_t *len);

/* A table HDU opened for browsing: any cell, formatted on demand. */
typedef struct fq_table fq_table;
typedef struct {
    char name[48];            /* TTYPE, or "col3" */
    char unit[24];            /* TUNIT */
    char form[24];            /* TFORM */
    int numeric;              /* align to the right */
} fq_column;

/* NULL if HDU hdu is not a table. f must stay open while t is in use. */
fq_table *fq_table_open(fq_file *f, int hdu);
void fq_table_close(fq_table *t);
int64_t fq_table_rows(const fq_table *t);   /* rows in the file (fewer if truncated) */
int fq_table_ncols(const fq_table *t);
const fq_column *fq_table_column(const fq_table *t, int col);
/* Cell text, as in fq_table_text but up to n-1 characters (arrays show
   their first values, variable-length arrays their length). */
void fq_table_cell(const fq_table *t, int64_t row, int col, char *out, size_t n);
/* Header cards of one HDU, one per line. malloc'd, NULL if no such HDU. */
char *fq_header_text(fq_file *f, int hdu, size_t *len);
/* The same cards split for display, one per line: kind, key, value and
   comment separated by tabs. Kind 'v': a keyword with a value (strings in
   quotes without their padding, long strings joined from CONTINUE cards,
   HIERARCH keywords in full); 'c': commentary (COMMENT, HISTORY, a blank
   keyword), its text in the comment; 'e': END. malloc'd, NULL if no such
   HDU. */
char *fq_header_cards(fq_file *f, int hdu, size_t *len);
/* The cards laid out for reading: keys in a column, values after " = "
   and comments after " / " lined up, COMMENT and HISTORY text where the
   values go; one card per line, ASCII. *spans (malloc'd, NULL if none)
   marks the parts to style, as byte offsets into the text. malloc'd, NULL
   if no such HDU. */
enum { FQ_SPAN_KEY = 1, FQ_SPAN_MARK = 2 /* " = ", " / " */, FQ_SPAN_COMMENT = 3 };
typedef struct {
    uint32_t start, len;
    int kind;
} fq_span;
char *fq_header_layout(fq_file *f, int hdu, size_t *len, fq_span **spans, size_t *nspans);
/* One line per HDU describing its contents. malloc'd. */
char *fq_summary_text(fq_file *f);
/* Value of a keyword (strings unquoted). Returns 1 if found. */
int fq_keyword(fq_file *f, int hdu, const char *key, char *val, size_t vallen);

#ifdef __cplusplus
}
#endif
#endif
