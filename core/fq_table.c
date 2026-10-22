/*
 * fq_table.c - uFits core: binary tables.
 *
 * Tables that hold a light curve (a time column and a flux column), a
 * spectrum (wavelength and flux columns) or a catalog (RA and Dec columns)
 * are plotted, and any table can be listed as text, first rows only. Only
 * the bytes of the columns used are read.
 */
#define _DEFAULT_SOURCE 1
#define _DARWIN_C_SOURCE 1

#include "fq.h"
#include "fq_internal.h"

#include <ctype.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <unistd.h>

#define MAX_COLS 999
#define PLOT_MAX_POINTS ((int64_t)20000000)  /* bigger tables are sampled */
/* A plot of a table bigger than PLOT_READ_ALL (with as many rows as
   windows) reads PLOT_WINDOWS windows of PLOT_WINDOW bytes, 256 MiB in all:
   one in each of as many equal parts of the table, at a random place in it
   (the same each time), so that no regular step beats with the order of
   the rows. */
#define PLOT_READ_ALL ((int64_t)1 << 30)
#define PLOT_WINDOW ((int64_t)16 << 10)
#define PLOT_WINDOWS 16384
/* From PLOT_PARALLEL points on, a plot is drawn on every core (at most
   PLOT_WORKERS of them for its second pass), in PLOT_SLICES slices. */
#define PLOT_PARALLEL ((int64_t)4 << 20)
#define PLOT_SLICES 64
#define PLOT_WORKERS 8
#define PLOT_BLOCK 1024                      /* points decoded at a time */
#define PLOT_AHEAD 4                         /* windows asked for ahead of use */
#define CELL 28                              /* widest column in listings */
#define LIST_COLS 60                         /* columns shown in listings */

typedef struct {
    char name[48];
    char unit[24];
    char form[24];
    char type;          /* element type letter */
    char desc;          /* 'P' or 'Q' for variable length arrays */
    int64_t repeat;     /* elements per row */
    int64_t off;        /* byte offset in the row */
    int64_t width;      /* bytes per row */
    double scale, zero;
    int has_null;
    int64_t null;
} tcol;

/* n for a card named PREFIXn (n = 1...999), else 0. */
static int key_index(const char *c, const char *prefix)
{
    size_t k = strlen(prefix), j = k;
    if (memcmp(c, prefix, k) != 0)
        return 0;
    int n = 0;
    for (; j < 8 && isdigit((unsigned char)c[j]); j++)
        n = n * 10 + (c[j] - '0');
    if (j == k)
        return 0;
    for (; j < 8; j++)
        if (c[j] != ' ')
            return 0;
    return n;
}

static int parse_double(const char *s, double *v)
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

/* An ASCII table column: TFORM Aw, Iw, Fw.d, Ew.d or Dw.d. */
static int ascii_form(tcol *t, int64_t bcol, int64_t rowlen)
{
    const char *s = t->form;
    while (*s == ' ')
        s++;
    if (!strchr("AIFED", toupper((unsigned char)*s)))
        return -1;
    int64_t w = 0;
    for (s++; isdigit((unsigned char)*s) && w < 100000; s++)
        w = w * 10 + (*s - '0');
    if (w < 1 || bcol < 1 || bcol > rowlen || w > rowlen - (bcol - 1))
        return -1;
    t->type = 'a';
    t->repeat = 1;
    t->off = bcol - 1;
    t->width = w;
    return 0;
}

/* The columns of a binary or ASCII table, from one pass over its header.
   Returns the number of columns (*out malloc'd) or -1. */
static int read_columns(const fq_file *f, const hdu_t *h, tcol **out)
{
    const int ascii = !strcmp(h->xtension, "TABLE");
    int64_t tfields;
    if (!fqi_kw_int(f, h, "TFIELDS", &tfields) || tfields < 1 || tfields > MAX_COLS)
        return -1;
    int nc = (int)tfields;
    tcol *cols = calloc((size_t)nc, sizeof *cols);
    if (!cols)
        return -1;
    int64_t *bcol = ascii ? calloc((size_t)nc, sizeof *bcol) : NULL;
    if (ascii && !bcol) {
        free(cols);
        return -1;
    }
    for (int i = 0; i < nc; i++)
        cols[i].scale = 1;
    const char *p = (const char *)f->data + h->hdr_off;
    int64_t ncard = h->hdr_len / CARD;
    char v[CARD];
    double d;
    for (int64_t i = 0; i < ncard; i++) {
        const char *c = p + i * CARD;
        if (c[0] != 'T') {
            if (c[0] == 'E' && memcmp(c, "END     ", 8) == 0)
                break;
            continue;
        }
        int n;
        if ((n = key_index(c, "TTYPE")) && n <= nc) {
            if (fqi_card_value(c, v, sizeof v) >= 0)
                fqi_scopy(cols[n - 1].name, sizeof cols[n - 1].name, v);
        } else if ((n = key_index(c, "TFORM")) && n <= nc) {
            if (fqi_card_value(c, v, sizeof v) >= 0)
                fqi_scopy(cols[n - 1].form, sizeof cols[n - 1].form, v);
        } else if ((n = key_index(c, "TUNIT")) && n <= nc) {
            if (fqi_card_value(c, v, sizeof v) >= 0)
                fqi_scopy(cols[n - 1].unit, sizeof cols[n - 1].unit, v);
        } else if ((n = key_index(c, "TSCAL")) && n <= nc) {
            if (fqi_card_value(c, v, sizeof v) >= 0 && parse_double(v, &d) && d != 0)
                cols[n - 1].scale = d;
        } else if ((n = key_index(c, "TZERO")) && n <= nc) {
            if (fqi_card_value(c, v, sizeof v) >= 0 && parse_double(v, &d))
                cols[n - 1].zero = d;
        } else if ((n = key_index(c, "TBCOL")) && n <= nc && ascii) {
            if (fqi_card_value(c, v, sizeof v) >= 0)
                bcol[n - 1] = strtoll(v, NULL, 10);
        } else if ((n = key_index(c, "TNULL")) && n <= nc && !ascii) {
            char *end;
            if (fqi_card_value(c, v, sizeof v) >= 0) {
                long long x = strtoll(v, &end, 10);
                if (end != v) {
                    cols[n - 1].has_null = 1;
                    cols[n - 1].null = x;
                }
            }
        }
    }
    int64_t off = 0;
    for (int i = 0; i < nc && off >= 0; i++) {
        tcol *t = &cols[i];
        if (ascii) {
            if (ascii_form(t, bcol[i], h->naxes[0]) != 0)
                off = -1;
            continue;
        }
        int64_t width = t->form[0] ? fqi_parse_tform(t->form, &t->repeat, &t->type, &t->desc) : -1;
        if (width < 0) {
            off = -1;
            break;
        }
        t->off = off;
        t->width = width;
        off = fqi_add_sat(off, width);
    }
    free(bcol);
    if (off < 0 || off > h->naxes[0]) {
        free(cols);
        return -1;
    }
    *out = cols;
    return nc;
}

static int is_numeric(const tcol *t)
{
    return !t->desc && t->repeat >= 1 && t->type && strchr("BIJKED", t->type) != NULL;
}

static int find_col(const tcol *cols, int n, const char *name)
{
    for (int i = 0; i < n; i++)
        if (!strcasecmp(cols[i].name, name) && is_numeric(&cols[i]))
            return i;
    return -1;
}

/* Column names that mark a light curve or a spectrum, best first. */
static const char *const lc_x[] = { "TIME", "BTJD", "BKJD", "BJD", "BJD_TDB", "HJD", "MJD", "JD", NULL };
static const char *const lc_y[] = { "PDCSAP_FLUX", "SAP_FLUX", "FLUX", "RATE", "NET_RATE",
                                    "COUNT_RATE", "MAG", "MAGNITUDE", "COUNTS", NULL };
static const char *const sp_x[] = { "WAVELENGTH", "WAVE", "LAMBDA", "LAM", "LOGLAM", "FREQUENCY",
                                    "FREQ", "ENERGY", "VELOCITY", "VELO", "CHANNEL", NULL };
static const char *const sp_y[] = { "FLUX", "FLUX_DENSITY", "FLAM", "F_LAMBDA", "FNU", "F_NU", "SPEC",
                                    "SPECTRUM", "INTENSITY", "COUNTS", "RATE", "DATA", NULL };

/* Catalog positions: right ascension and declination as names go
   (SDSS/Gaia, VizieR, SExtractor, Pan-STARRS, DESI, ...), then galactic. */
static const char *const sky_xy[][2] = {
    { "RA", "DEC" },           { "RAJ2000", "DEJ2000" },     { "_RAJ2000", "_DEJ2000" },
    { "RA_ICRS", "DE_ICRS" },  { "RAJ2000", "DECJ2000" },    { "RA_J2000", "DEC_J2000" },
    { "ALPHA_J2000", "DELTA_J2000" }, { "ALPHAWIN_J2000", "DELTAWIN_J2000" },
    { "RAMEAN", "DECMEAN" },   { "RA_OBJ", "DEC_OBJ" },      { "TARGET_RA", "TARGET_DEC" },
    { "RA_DEG", "DEC_DEG" },   { "RADEG", "DECDEG" },        { "GLON", "GLAT" },
    { NULL, NULL }
};

static int pick(const tcol *cols, int n, const char *const *xs, const char *const *ys, int *xc, int *yc)
{
    for (const char *const *x = xs; *x; x++) {
        int i = find_col(cols, n, *x);
        if (i < 0)
            continue;
        for (const char *const *y = ys; *y; y++) {
            int j = find_col(cols, n, *y);
            if (j >= 0 && j != i && cols[j].repeat == cols[i].repeat) {
                *xc = i;
                *yc = j;
                return 1;
            }
        }
    }
    return 0;
}

int fqi_table_plot_spec(fq_file *f, int idx, fqi_plotspec *ps)
{
    memset(ps, 0, sizeof *ps);
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h || strcmp(h->xtension, "BINTABLE") != 0 || h->zimage || h->naxis != 2 || h->naxes[1] < 1)
        return 0;
    tcol *cols;
    int n = read_columns(f, h, &cols);
    if (n <= 0)
        return 0;
    int xc = -1, yc = -1, ok = 0;
    if (pick(cols, n, lc_x, lc_y, &xc, &yc)) {
        ok = 1;
        ps->points = 1;
    } else if (pick(cols, n, sp_x, sp_y, &xc, &yc)) {
        ok = 1;
    } else {
        for (int k = 0; sky_xy[k][0] && !ok; k++) {
            xc = find_col(cols, n, sky_xy[k][0]);
            yc = find_col(cols, n, sky_xy[k][1]);
            ok = xc >= 0 && yc >= 0 && cols[xc].repeat == cols[yc].repeat;
        }
        ps->points = ps->sky = ok;
    }
    if (ok) {
        ps->xcol = xc;
        ps->ycol = yc;
        ps->xlog = !strcasecmp(cols[xc].name, "LOGLAM");
        ps->yflip = !strncasecmp(cols[yc].name, "MAG", 3);
        ps->nrows = h->naxes[1];
        ps->repeat = cols[xc].repeat;
        fqi_scopy(ps->xname, sizeof ps->xname, cols[xc].name);
        fqi_scopy(ps->yname, sizeof ps->yname, cols[yc].name);
        if (fqi_mul_sat(ps->nrows, ps->repeat) < 2)
            ok = 0;
    }
    free(cols);
    return ok;
}

/* Element e of a numeric column, scaled; NaN for nulls. */
static double cell_value(const uint8_t *row, const tcol *t, int64_t e)
{
    const uint8_t *p = row + t->off;
    int64_t iv;
    double v;
    switch (t->type) {
    case 'B': iv = p[e]; break;
    case 'I': iv = (int16_t)fq_be16(p + 2 * e); break;
    case 'J': iv = (int32_t)fq_be32(p + 4 * e); break;
    case 'K': iv = (int64_t)fq_be64(p + 8 * e); break;
    case 'E': {
        uint32_t u = fq_be32(p + 4 * e);
        float x;
        memcpy(&x, &u, 4);
        return x * t->scale + t->zero;
    }
    case 'D': {
        uint64_t u = fq_be64(p + 8 * e);
        memcpy(&v, &u, 8);
        return v * t->scale + t->zero;
    }
    default:
        return NAN;
    }
    if (t->has_null && iv == t->null)
        return NAN;
    return (double)iv * t->scale + t->zero;
}

/* The points of a plot are k = row * repeat + element. A plot reads those
   of each run [k0, k1), at k0, k0 + step, ...: a run is a window of rows
   of a big table, or a slice of the points of a smaller one. */
typedef struct {
    int64_t k0, k1;
} prun;

typedef struct {
    double xmin, xmax, wmin, wmax, ymin, ymax;
    int64_t nvalid, ns;
} pass1_t;

typedef struct {
    const uint8_t *base;
    int64_t rowlen, rep, step;
    tcol tx, ty;
    const fqi_plotspec *ps;
    const prun *runs;
    int64_t nruns;
    int nslices;            /* slice s: runs [s * nruns / nslices, (s + 1) * nruns / nslices) */
    pass1_t *p1;            /* of each slice */
    float *samp;            /* y samples, those of slice s from samp_at[s] */
    const int64_t *samp_at;
    int64_t sstep;
    float *spread;          /* windows of sky positions: how far apart their
                               points are in x, then in y (NaN: fewer than 2) */
    uintptr_t page;         /* windows in the mapped file: the page size */
    int wrap, one, ncol, nrow, nworkers;
    double xmin, per, ymin, rowper;
    float *lo[PLOT_WORKERS], *hi[PLOT_WORKERS];
    uint8_t *dots[PLOT_WORKERS];
    int64_t plotted[PLOT_WORKERS];
} plotjob;

/* Column t at points k0, k0 + step, ... (n of them), as cell_value gives
   them: of a column of one float a row, without looking at its type for
   each. */
static void column_block(const plotjob *J, const tcol *t, int64_t k0, int n, double *out)
{
    const int64_t step = J->step;
    if (J->rep == 1 && (t->type == 'D' || t->type == 'E')) {
        const uint8_t *p = J->base + k0 * J->rowlen + t->off;
        const int64_t d = step * J->rowlen;
        const double sc = t->scale, zo = t->zero;
        if (t->type == 'D') {
            for (int i = 0; i < n; i++, p += d) {
                uint64_t u = fq_be64(p);
                double v;
                memcpy(&v, &u, 8);
                out[i] = v * sc + zo;
            }
        } else {
            for (int i = 0; i < n; i++, p += d) {
                uint32_t u = fq_be32(p);
                float v;
                memcpy(&v, &u, 4);
                out[i] = v * sc + zo;
            }
        }
        return;
    }
    for (int i = 0; i < n; i++) {
        int64_t k = k0 + i * step;
        out[i] = cell_value(J->base + (k / J->rep) * J->rowlen, t, k % J->rep);
    }
}

/* Whether a point is plotted, and its x as plotted. Sky positions outside
   the sphere's ranges are placeholders (-999 and the like); with wrap,
   right ascensions above 180 become negative. */
static inline int point_ok(const fqi_plotspec *ps, int wrap, double *x, double y)
{
    if (ps->xlog)
        *x = pow(10.0, *x);
    if (!isfinite(*x) || !isfinite(y))
        return 0;
    if (ps->sky) {
        if (*x < -360 || *x > 360 || y < -90 || y > 90)
            return 0;
        if (wrap && *x > 180)
            *x -= 360;
    }
    return 1;
}

/* How many of the points from k on, below k1, a block takes: at most
   PLOT_BLOCK. */
static int block_len(const plotjob *J, int64_t k, int64_t k1)
{
    int64_t left = (k1 - k + J->step - 1) / J->step;
    return left < PLOT_BLOCK ? (int)left : PLOT_BLOCK;
}

/* Asks for the rows of run i (a window in the mapped file) to be read. */
static void ask_run(const plotjob *J, int64_t i)
{
    const prun *r = &J->runs[i];
    if (!J->page || r->k1 <= r->k0)
        return;
    uintptr_t a = (uintptr_t)(J->base + r->k0 / J->rep * J->rowlen) & ~(J->page - 1);
    uintptr_t e = (uintptr_t)(J->base + r->k1 / J->rep * J->rowlen);
    posix_madvise((void *)a, (size_t)(e - a), POSIX_MADV_WILLNEED);
}

/* Pass 1, slice s: the x range, a subsample of y for the plot range, and
   how far apart the points of each window of sky positions are. For sky
   positions also the range with right ascension in -180...180, which is
   smaller when the field straddles RA = 0. */
static void plot_pass1(void *ctx, size_t s)
{
    plotjob *J = ctx;
    pass1_t r = { INFINITY, -INFINITY, INFINITY, -INFINITY, INFINITY, -INFINITY, 0, 0 };
    float *samp = J->samp + J->samp_at[s];
    double xs[PLOT_BLOCK], ys[PLOT_BLOCK];
    const int64_t i0 = J->nruns * (int64_t)s / J->nslices, i1 = J->nruns * (int64_t)(s + 1) / J->nslices;
    for (int64_t i = i0; i < i0 + PLOT_AHEAD && i < i1; i++)
        ask_run(J, i);
    for (int64_t i = i0; i < i1; i++) {
        double x0 = INFINITY, x1 = -INFINITY, y0 = INFINITY, y1 = -INFINITY;
        int64_t valid = 0;
        if (i + PLOT_AHEAD < i1)
            ask_run(J, i + PLOT_AHEAD);
        for (int64_t k = J->runs[i].k0; k < J->runs[i].k1; k += PLOT_BLOCK * J->step) {
            int n = block_len(J, k, J->runs[i].k1);
            column_block(J, &J->tx, k, n, xs);
            column_block(J, &J->ty, k, n, ys);
            for (int j = 0; j < n; j++) {
                double x = xs[j], y = ys[j];
                if (!point_ok(J->ps, 0, &x, y))
                    continue;
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
                double w = x > 180 ? x - 360 : x;
                if (w < r.wmin) r.wmin = w;
                if (w > r.wmax) r.wmax = w;
                valid++;
                if (r.nvalid++ % J->sstep == 0)
                    samp[r.ns++] = (float)y;
            }
        }
        if (x0 < r.xmin) r.xmin = x0;
        if (x1 > r.xmax) r.xmax = x1;
        if (y0 < r.ymin) r.ymin = y0;
        if (y1 > r.ymax) r.ymax = y1;
        if (J->spread) {
            J->spread[i] = valid > 1 ? (float)(x1 - x0) : NAN;
            J->spread[J->nruns + i] = valid > 1 ? (float)(y1 - y0) : NAN;
        }
    }
    J->p1[s] = r;
}

/* Pass 2, worker t (slices [t * nslices / nworkers, (t + 1) * nslices /
   nworkers)): min and max of y in evenly spaced x columns, and the points
   in the cells of a grid, into its own columns and grid. */
static void plot_pass2(void *ctx, size_t t)
{
    plotjob *J = ctx;
    float *lo = J->lo[t], *hi = J->hi[t];
    uint8_t *dots = J->dots[t];
    const int ncol = J->ncol, nrow = J->nrow;
    double xs[PLOT_BLOCK], ys[PLOT_BLOCK];
    int64_t plotted = 0;
    const int64_t s0 = J->nslices * (int64_t)t / J->nworkers, s1 = J->nslices * (int64_t)(t + 1) / J->nworkers;
    const int64_t i1 = J->nruns * s1 / J->nslices;
    for (int64_t i = J->nruns * s0 / J->nslices; i < i1; i++) {
        int64_t k0 = J->runs[i].k0, k1 = J->runs[i].k1;
        if (J->one && k1 - k0 > J->rep) {   /* a sorted catalog: a window's middle row */
            k0 += (k1 - k0) / J->rep / 2 * J->rep;
            k1 = k0 + J->rep;
        }
        for (int64_t k = k0; k < k1; k += PLOT_BLOCK * J->step) {
            int n = block_len(J, k, k1);
            column_block(J, &J->tx, k, n, xs);
            column_block(J, &J->ty, k, n, ys);
            for (int j = 0; j < n; j++) {
                double x = xs[j], y = ys[j];
                if (!point_ok(J->ps, J->wrap, &x, y))
                    continue;
                plotted++;
                int c = ncol > 1 ? (int)((x - J->xmin) * J->per) : 0;
                if (c >= ncol)
                    c = ncol - 1;
                if (c < 0)
                    c = 0;
                float v = (float)y;
                if (!(v >= lo[c]))
                    lo[c] = v;
                if (!(v <= hi[c]))
                    hi[c] = v;
                if (nrow) {
                    double rr = (y - J->ymin) * J->rowper;   /* off the plot: no dot */
                    if (rr >= 0 && rr < nrow) {
                        uint8_t *cell = &dots[(size_t)c * (size_t)nrow + (size_t)rr];
                        if (*cell < 255)
                            (*cell)++;
                    }
                }
            }
        }
    }
    J->plotted[t] = plotted;
}

/* Rows [*r0, *r1) of window k of the rows of a table (data_off its first
   byte): those wholly inside it, or the one row starting in it when rows
   are longer than a window. */
static void window_rows(int64_t data_off, int64_t rowlen, int64_t rows, int64_t k, int64_t *r0,
                        int64_t *r1)
{
    const int64_t part = rows * rowlen / PLOT_WINDOWS;
    uint64_t z = (uint64_t)k * 0x9E3779B97F4A7C15ull;   /* splitmix64: fixed, so plots repeat */
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    int64_t at = data_off + part * k + (int64_t)(z % (uint64_t)(part - PLOT_WINDOW + 1));
    at -= at % PLOT_WINDOW;
    if (at < data_off)
        at = data_off;
    int64_t a = (at - data_off + rowlen - 1) / rowlen;
    int64_t b = (at + PLOT_WINDOW - data_off) / rowlen;
    if (b <= a)
        b = a + 1;
    *r0 = a < rows ? a : rows;
    *r1 = b < rows ? b : rows;
}

static void plotjob_free(plotjob *J)
{
    for (int t = 1; t < PLOT_WORKERS; t++) {
        free(J->lo[t]);
        free(J->hi[t]);
        free(J->dots[t]);
    }
    free((void *)J->runs);
    free(J->p1);
    free(J->samp);
    free((void *)J->samp_at);
    free(J->spread);
}

int fqi_table_plot(fq_file *f, int idx, const fq_opts *o, fq_image *img, char *err, size_t errlen)
{
    fqi_plotspec ps;
    if (!fqi_table_plot_spec(f, idx, &ps)) {
        fqi_seterr(err, errlen, "HDU %d has no columns to plot", idx);
        return -1;
    }
    hdu_t *h = fqi_get_hdu(f, idx);
    const int64_t rowlen = h->naxes[0], nrows = h->naxes[1];
    if (rowlen < 1) {
        fqi_seterr(err, errlen, "empty table rows");
        return -1;
    }
    fqi_need(f, fqi_add_sat(h->data_off, fqi_mul_sat(rowlen, nrows)));
    h = fqi_get_hdu(f, idx);
    tcol *cols;
    if (read_columns(f, h, &cols) <= 0) {
        fqi_seterr(err, errlen, "cannot read the table columns");
        return -1;
    }
    plotjob J;
    memset(&J, 0, sizeof J);
    void *adv = NULL;   /* the rows given POSIX_MADV_RANDOM */
    size_t advlen = 0;
    J.tx = cols[ps.xcol];
    J.ty = cols[ps.ycol];
    free(cols);

    int64_t avail = f->size - h->data_off;
    int64_t rows = avail > 0 ? avail / rowlen : 0;
    if (rows > nrows)
        rows = nrows;
    const uint8_t *base = f->data + h->data_off;
    const int64_t rep = ps.repeat;
    J.base = base;
    J.rowlen = rowlen;
    J.rep = rep;
    J.ps = &ps;

    /* The runs: windows of a big table, else slices of its points. */
    const int64_t nwin = fqi_mul_sat(rows, rowlen) > PLOT_READ_ALL && rows >= PLOT_WINDOWS ? PLOT_WINDOWS : 0;
    prun *runs = NULL;
    int64_t total = 0;   /* points in the runs */
    if (nwin) {
        if (!(runs = malloc((size_t)nwin * sizeof *runs)))
            goto oom;
        for (int64_t w = 0; w < nwin; w++) {
            int64_t r0, r1;
            window_rows(h->data_off, rowlen, rows, w, &r0, &r1);
            runs[w].k0 = fqi_mul_sat(r0, rep);
            runs[w].k1 = fqi_mul_sat(r1, rep);
            total = fqi_add_sat(total, runs[w].k1 - runs[w].k0);
        }
    } else {
        total = fqi_mul_sat(rows, rep);
    }
    J.step = total > PLOT_MAX_POINTS ? total / (PLOT_MAX_POINTS / 2) : 1;
    J.nslices = total / J.step < PLOT_PARALLEL ? 1 : PLOT_SLICES;
    if (!nwin) {
        /* Slices of the points 0, step, 2 step, ... */
        if (!(runs = malloc((size_t)J.nslices * sizeof *runs)))
            goto oom;
        for (int s = 0; s < J.nslices; s++) {
            int64_t b[2];
            for (int e = 0; e < 2; e++) {
                int64_t q = s + e, at = total / J.nslices * q + (q < total % J.nslices ? q : total % J.nslices);
                b[e] = at % J.step ? at + (J.step - at % J.step) : at;
                if (b[e] > total)
                    b[e] = total;
            }
            runs[s].k0 = b[0];
            runs[s].k1 = b[1];
        }
    }
    J.runs = runs;
    J.nruns = nwin ? nwin : J.nslices;
    J.sstep = total / J.step / STAT_SAMPLES + 1;

    /* Room for each slice's y samples. */
    int64_t *samp_at = malloc(((size_t)J.nslices + 1) * sizeof *samp_at);
    J.samp_at = samp_at;
    J.p1 = calloc((size_t)J.nslices, sizeof *J.p1);
    if (!samp_at || !J.p1)
        goto oom;
    samp_at[0] = 0;
    for (int s = 0; s < J.nslices; s++) {
        int64_t points = 0;
        for (int64_t i = J.nruns * s / J.nslices; i < J.nruns * (s + 1) / J.nslices; i++)
            if (runs[i].k1 > runs[i].k0)
                points += (runs[i].k1 - runs[i].k0 + J.step - 1) / J.step;
        samp_at[s + 1] = samp_at[s] + points / J.sstep + 2;
    }
    J.samp = malloc((size_t)samp_at[J.nslices] * sizeof(float));
    if (!J.samp)
        goto oom;
    if (nwin && ps.sky && !(J.spread = malloc(2 * (size_t)nwin * sizeof(float))))
        goto oom;

    /* Windows are read where they are, without the read-ahead meant for
       reading on (which would read far more than the windows), on every
       core: the reads overlap. Since macOS 15.4 a hint to read ahead reads
       before it returns, so it would not. */
    const uintptr_t map = (uintptr_t)f->map, from = (uintptr_t)base;
    if (nwin && f->map && from >= map && from - map + (uint64_t)(rows * rowlen) <= f->maplen) {
        J.page = (uintptr_t)sysconf(_SC_PAGESIZE);
        adv = (void *)(from & ~(J.page - 1));
        advlen = (size_t)(from + (uintptr_t)(rows * rowlen) - (uintptr_t)adv);
        posix_madvise(adv, advlen, POSIX_MADV_RANDOM);
    }

    /* Pass 1, then the slices' results in order. */
    fqi_par_for((size_t)J.nslices, o->threads, &J, plot_pass1);
    double xmin = INFINITY, xmax = -INFINITY, wmin = INFINITY, wmax = -INFINITY;
    double ymin = INFINITY, ymax = -INFINITY;
    int64_t nvalid = 0, ns = 0;
    for (int s = 0; s < J.nslices; s++) {
        const pass1_t *r = &J.p1[s];
        if (r->xmin < xmin) xmin = r->xmin;
        if (r->xmax > xmax) xmax = r->xmax;
        if (r->wmin < wmin) wmin = r->wmin;
        if (r->wmax > wmax) wmax = r->wmax;
        if (r->ymin < ymin) ymin = r->ymin;
        if (r->ymax > ymax) ymax = r->ymax;
        nvalid += r->nvalid;
        memmove(J.samp + ns, J.samp + samp_at[s], (size_t)r->ns * sizeof(float));
        ns += r->ns;
    }
    if (!nvalid) {
        fqi_seterr(err, errlen, "no valid values in %s and %s", ps.xname, ps.yname);
        goto fail;
    }
    /* Right ascension in -180...180 when that makes the field narrower: by
       more than a degree, so that an all-sky catalog does not turn on its
       few outermost points. */
    J.wrap = ps.sky && wmax - wmin < xmax - xmin - 1;
    /* Sorted by position, the rows of a window are one small patch of sky:
       all of them would draw the windows, not the catalog. Then one row of
       each is drawn. */
    if (J.spread && xmax > xmin && ymax > ymin) {
        int64_t m[2] = { 0, 0 };
        for (int d = 0; d < 2; d++) {
            float *v = J.spread + d * nwin;
            for (int64_t i = 0; i < nwin; i++)
                if (v[i] == v[i])
                    v[m[d]++] = v[i];
        }
        if (m[0] > 0 && m[1] > 0) {
            double sx = fqi_percentile(J.spread, m[0], 0.5) / (xmax - xmin);
            double sy = fqi_percentile(J.spread + nwin, m[1], 0.5) / (ymax - ymin);
            J.one = sx < 0.25 || sy < 0.25;
        }
    }
    if (J.wrap) {
        xmin = wmin;
        xmax = wmax;
    }

    /* Pass 2: min/max of y in evenly spaced x columns. */
    int ncol = o->max_width > 0 ? o->max_width : 1024;
    if (ps.points && ncol > 1600)   /* dots: finer than any screen needs */
        ncol = 1600;
    if (ncol > nvalid)
        ncol = (int)nvalid;
    if (!(xmax > xmin) || !isfinite(xmax - xmin))
        ncol = 1;
    img->spec_lo = malloc((size_t)ncol * sizeof(float));
    img->spec_hi = malloc((size_t)ncol * sizeof(float));
    if (!img->spec_lo || !img->spec_hi)
        goto oom;
    for (int c = 0; c < ncol; c++)
        img->spec_lo[c] = img->spec_hi[c] = NAN;
    fqi_plot_range(J.samp, ns, &img->y_min, &img->y_max);

    /* Time series and sky positions are drawn as dots: count the points in
       the cells of a grid, so that sparse and crowded parts both show. */
    int nrow = 0;
    if (ps.points) {
        nrow = ncol * 3 / 4;
        nrow = nrow < 16 ? 16 : nrow > 1024 ? 1024 : nrow;
        img->dots = calloc((size_t)ncol * (size_t)nrow, 1);
        if (!img->dots)
            goto oom;
        img->dot_rows = nrow;
    }
    const double span = xmax - xmin;
    J.ncol = ncol;
    J.nrow = nrow;
    J.xmin = xmin;
    J.per = ncol > 1 ? ncol / span : 0;
    J.ymin = img->y_min;
    J.rowper = nrow / (img->y_max - img->y_min);
    /* Workers past the first have columns and a grid of their own. */
    J.nworkers = 1;
    if (J.nslices > 1) {
        long cores = o->threads > 0 ? o->threads : sysconf(_SC_NPROCESSORS_ONLN);
        int want = cores < 1 ? 1 : cores > PLOT_WORKERS ? PLOT_WORKERS : (int)cores;
        for (; J.nworkers < want; J.nworkers++) {
            int t = J.nworkers;
            J.lo[t] = malloc((size_t)ncol * sizeof(float));
            J.hi[t] = malloc((size_t)ncol * sizeof(float));
            J.dots[t] = nrow ? calloc((size_t)ncol * (size_t)nrow, 1) : NULL;
            if (!J.lo[t] || !J.hi[t] || (nrow && !J.dots[t]))
                break;
            for (int c = 0; c < ncol; c++)
                J.lo[t][c] = J.hi[t][c] = NAN;
        }
    }
    J.lo[0] = img->spec_lo;
    J.hi[0] = img->spec_hi;
    J.dots[0] = img->dots;
    fqi_par_for((size_t)J.nworkers, o->threads, &J, plot_pass2);
    int64_t plotted = J.plotted[0];
    for (int t = 1; t < J.nworkers; t++) {
        for (int c = 0; c < ncol; c++) {
            float a = J.lo[t][c], b = J.hi[t][c];
            if (a == a && !(a >= img->spec_lo[c]))
                img->spec_lo[c] = a;
            if (b == b && !(b <= img->spec_hi[c]))
                img->spec_hi[c] = b;
        }
        if (nrow) {
            uint8_t *d = img->dots;
            const uint8_t *e = J.dots[t];
            for (size_t k = 0; k < (size_t)ncol * (size_t)nrow; k++) {
                unsigned v = (unsigned)d[k] + e[k];
                d[k] = (uint8_t)(v > 255 ? 255 : v);
            }
        }
        plotted += J.plotted[t];
    }
    J.lo[0] = J.hi[0] = NULL;
    J.dots[0] = NULL;
    if (adv)
        posix_madvise(adv, advlen, POSIX_MADV_NORMAL);
    plotjob_free(&J);

    img->spec_n = ncol;
    img->spec_points = plotted;
    img->has_x = 1;
    if (ncol > 1) {
        img->x_first = xmin + 0.5 * span / ncol;
        img->x_last = xmax - 0.5 * span / ncol;
    } else {
        img->x_first = img->x_last = 0.5 * xmin + 0.5 * xmax;
    }
    img->y_flip = ps.yflip;
    img->points = ps.points;
    img->x_flip = ps.sky;   /* east is left on the sky */
    img->x_wrap = J.wrap;
    if (ps.xlog) {   /* SDSS: log10 of the wavelength in Angstrom */
        fqi_scopy(img->x_label, sizeof img->x_label,
                  islower((unsigned char)ps.xname[0]) ? "wavelength" : "WAVELENGTH");
        fqi_scopy(img->x_unit, sizeof img->x_unit, "Angstrom");
    } else {
        fqi_scopy(img->x_label, sizeof img->x_label, ps.xname);
        fqi_scopy(img->x_unit, sizeof img->x_unit, J.tx.unit);
    }
    fqi_scopy(img->y_label, sizeof img->y_label, ps.yname);
    fqi_scopy(img->y_unit, sizeof img->y_unit, J.ty.unit);

    fq_info *in = &img->info;
    memset(in, 0, sizeof *in);
    in->kind = FQ_KIND_PLOT;
    in->table = 1;
    in->hdu = idx;
    fqi_scopy(in->extname, sizeof in->extname, h->extname);
    in->naxis = 1;
    in->naxes[0] = nrows;
    in->nplanes = 1;
    in->bin = 1;
    in->samples = 1;
    in->truncated = rows < nrows;
    return 0;

oom:
    fqi_seterr(err, errlen, "out of memory");
fail:
    if (adv)
        posix_madvise(adv, advlen, POSIX_MADV_NORMAL);
    J.lo[0] = J.hi[0] = NULL;
    J.dots[0] = NULL;
    plotjob_free(&J);
    return -1;
}

/* ------------------------------------------------------------- listings */

static void sb_pad(fqi_sbuf *b, const char *s, int width, int right)
{
    int n = (int)strlen(s);
    for (int i = n; right && i < width; i++)
        fqi_sb_add(b, " ", 1);
    fqi_sb_add(b, s, (size_t)n);
    for (int i = n; !right && i < width; i++)
        fqi_sb_add(b, " ", 1);
}

static void fmt_number(const uint8_t *row, const tcol *t, int64_t e, char *out, size_t n)
{
    int scaled = t->scale != 1.0 || t->zero != 0.0;
    if (strchr("BIJK", t->type)) {
        const uint8_t *p = row + t->off;
        long long iv = t->type == 'B'   ? p[e]
                       : t->type == 'I' ? (int16_t)fq_be16(p + 2 * e)
                       : t->type == 'J' ? (int32_t)fq_be32(p + 4 * e)
                                        : (long long)(int64_t)fq_be64(p + 8 * e);
        if (t->has_null && iv == t->null) {
            snprintf(out, n, "null");
            return;
        }
        if (!scaled) {
            snprintf(out, n, "%lld", iv);
            return;
        }
    }
    double v = cell_value(row, t, e);
    if (isnan(v))
        snprintf(out, n, "nan");
    else
        snprintf(out, n, t->type == 'D' || scaled ? "%.12g" : "%.7g", v);
}

/* One table cell as text in out (n bytes, n >= 32). Arrays show their
   first values; wider cells show more of them. */
static void fmt_cell(const uint8_t *row, const tcol *t, char *out, size_t n)
{
    const size_t max = n - 1;
    const uint8_t *p = row + t->off;
    out[0] = 0;
    if (t->repeat == 0)
        return;
    if (t->desc) {
        int64_t cnt = t->desc == 'P' ? (int64_t)fq_be32(p) : (int64_t)fq_be64(p);
        snprintf(out, n, "(%lld values)", (long long)cnt);
        return;
    }
    switch (t->type) {
    case 'a': {   /* ASCII table field: the text, trimmed */
        int64_t a = 0, b = t->width;
        while (a < b && p[a] == ' ')
            a++;
        while (b > a && p[b - 1] == ' ')
            b--;
        size_t k = 0;
        for (int64_t i = a; i < b && k < max; i++)
            out[k++] = (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
        out[k] = 0;
        return;
    }
    case 'A': {
        size_t k = 0;
        for (int64_t i = 0; i < t->repeat && p[i] && k < max; i++)
            out[k++] = (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
        while (k > 0 && out[k - 1] == ' ')
            k--;
        out[k] = 0;
        return;
    }
    case 'L': {
        size_t k = 0;
        for (int64_t i = 0; i < t->repeat && k + 2 < max; i++) {
            out[k++] = p[i] == 'T' ? 'T' : p[i] == 'F' ? 'F' : '-';
            if (i + 1 < t->repeat)
                out[k++] = ' ';
        }
        out[k] = 0;
        return;
    }
    case 'X': {
        size_t k = (size_t)snprintf(out, n, "0x");
        for (int64_t i = 0; i < t->width && k + 2 < max; i++)
            k += (size_t)snprintf(out + k, n - k, "%02x", p[i]);
        return;
    }
    case 'C':
    case 'M': {
        double re, im;
        if (t->type == 'C') {
            uint32_t a = fq_be32(p), b = fq_be32(p + 4);
            float fa, fb;
            memcpy(&fa, &a, 4);
            memcpy(&fb, &b, 4);
            re = fa;
            im = fb;
        } else {
            uint64_t a = fq_be64(p), b = fq_be64(p + 8);
            memcpy(&re, &a, 8);
            memcpy(&im, &b, 8);
        }
        snprintf(out, n, t->repeat > 1 ? "(%.4g, %.4g) ..." : "(%.6g, %.6g)", re, im);
        return;
    }
    }
    if (!strchr("BIJKED", t->type))
        return;
    if (t->repeat == 1) {
        fmt_number(row, t, 0, out, n);
        return;
    }
    const int64_t shown = max >= 64 ? 8 : 3;
    size_t k = 0;
    out[k++] = '[';
    for (int64_t i = 0; i < t->repeat && i < shown; i++) {
        char v[48];
        fmt_number(row, t, i, v, sizeof v);
        size_t vl = strlen(v);
        if (k + vl + 6 > max)
            break;
        if (i)
            out[k++] = ' ';
        memcpy(out + k, v, vl);
        k += vl;
    }
    if (t->repeat > shown && k + 4 <= max) {
        memcpy(out + k, " ...", 4);
        k += 4;
    }
    out[k++] = ']';
    out[k] = 0;
}

/* ------------------------------------------------------------- browsing */

struct fq_table {
    fq_file *f;
    int64_t data_off, rowlen, rows;
    int nc;
    tcol *cols;
    fq_column *info;
};

fq_table *fq_table_open(fq_file *f, int idx)
{
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h || h->naxis != 2 || h->zimage ||
        (strcmp(h->xtension, "BINTABLE") != 0 && strcmp(h->xtension, "TABLE") != 0))
        return NULL;
    const int64_t rowlen = h->naxes[0], nrows = h->naxes[1];
    fqi_need(f, fqi_add_sat(h->data_off, fqi_mul_sat(rowlen, nrows)));
    h = fqi_get_hdu(f, idx);
    fq_table *t = calloc(1, sizeof *t);
    if (!t)
        return NULL;
    t->nc = read_columns(f, h, &t->cols);
    t->info = t->nc > 0 ? calloc((size_t)t->nc, sizeof *t->info) : NULL;
    if (!t->info) {
        if (t->nc > 0)
            free(t->cols);
        free(t);
        return NULL;
    }
    for (int c = 0; c < t->nc; c++) {
        const tcol *tc = &t->cols[c];
        fq_column *ci = &t->info[c];
        if (tc->name[0])
            fqi_scopy(ci->name, sizeof ci->name, tc->name);
        else
            snprintf(ci->name, sizeof ci->name, "col%d", c + 1);
        fqi_scopy(ci->unit, sizeof ci->unit, tc->unit);
        fqi_scopy(ci->form, sizeof ci->form, tc->form);
        ci->numeric = tc->type == 'a' ? toupper((unsigned char)tc->form[0]) != 'A'
                                      : tc->type != 'A' && tc->type != 'L';
    }
    t->f = f;
    t->data_off = h->data_off;
    t->rowlen = rowlen;
    int64_t avail = f->size - h->data_off;
    t->rows = rowlen < 1 ? nrows : avail > 0 ? avail / rowlen : 0;
    if (t->rows > nrows)
        t->rows = nrows;
    return t;
}

void fq_table_close(fq_table *t)
{
    if (!t)
        return;
    free(t->cols);
    free(t->info);
    free(t);
}

int64_t fq_table_rows(const fq_table *t) { return t ? t->rows : 0; }

int fq_table_ncols(const fq_table *t) { return t ? t->nc : 0; }

const fq_column *fq_table_column(const fq_table *t, int col)
{
    return t && col >= 0 && col < t->nc ? &t->info[col] : NULL;
}

void fq_table_cell(const fq_table *t, int64_t row, int col, char *out, size_t n)
{
    if (!out || !n)
        return;
    out[0] = 0;
    if (!t || row < 0 || row >= t->rows || col < 0 || col >= t->nc)
        return;
    char buf[200];
    fmt_cell(t->f->data + t->data_off + row * t->rowlen, &t->cols[col], buf,
             n < 32 ? 32 : n < sizeof buf ? n : sizeof buf);
    fqi_scopy(out, n, buf);
}

char *fq_table_text(fq_file *f, int idx, int maxrows, size_t *len)
{
    hdu_t *h = fqi_get_hdu(f, idx);
    if (!h || h->naxis != 2 || h->zimage ||
        (strcmp(h->xtension, "BINTABLE") != 0 && strcmp(h->xtension, "TABLE") != 0))
        return NULL;
    const int64_t rowlen = h->naxes[0], nrows = h->naxes[1];
    int64_t show = maxrows < nrows ? maxrows : nrows;
    if (show < 0)
        show = 0;
    fqi_need(f, fqi_add_sat(h->data_off, fqi_mul_sat(rowlen, show)));
    h = fqi_get_hdu(f, idx);
    int64_t avail = f->size - h->data_off;
    if (rowlen > 0 && avail / rowlen < show)
        show = avail > 0 ? avail / rowlen : 0;
    const uint8_t *base = f->data + h->data_off;

    tcol *cols;
    int nc = read_columns(f, h, &cols);
    if (nc <= 0)
        return NULL;
    int shown = nc < LIST_COLS ? nc : LIST_COLS;
    int *width = calloc((size_t)shown, sizeof(int));
    char *cells = malloc((size_t)(show * shown + 1) * (CELL + 1));
    char(*sub)[CELL + 1] = malloc((size_t)shown * (CELL + 1));
    fqi_sbuf b = { 0 };
    if (!width || !cells || !sub) {
        b.oom = 1;
        goto done;
    }
    /* Column names, then TFORM and unit, then the cells. */
    for (int c = 0; c < shown; c++) {
        tcol *t = &cols[c];
        if (!t->name[0])
            snprintf(t->name, sizeof t->name, "col%d", c + 1);
        if (t->unit[0])
            snprintf(sub[c], CELL + 1, "%.10s [%.14s]", t->form, t->unit);
        else
            snprintf(sub[c], CELL + 1, "%.20s", t->form);
        int w = (int)strlen(t->name);
        if ((int)strlen(sub[c]) > w)
            w = (int)strlen(sub[c]);
        width[c] = w > CELL ? CELL : w;
    }
    for (int64_t r = 0; r < show; r++)
        for (int c = 0; c < shown; c++) {
            char *cell = cells + (r * shown + c) * (CELL + 1);
            fmt_cell(base + r * rowlen, &cols[c], cell, CELL + 1);
            int w = (int)strlen(cell);
            if (w > width[c])
                width[c] = w;
        }
    fqi_sb_printf(&b, "%lld row%s x %d column%s", (long long)nrows, nrows == 1 ? "" : "s", nc,
              nc == 1 ? "" : "s");
    if (show < nrows)
        fqi_sb_printf(&b, ", first %lld rows", (long long)show);
    if (shown < nc)
        fqi_sb_printf(&b, ", first %d columns", shown);
    fqi_sb_add(&b, "\n\n", 2);
    for (int line = 0; line < 2; line++)
        for (int c = 0; c < shown; c++) {
            char name[CELL + 1];
            fqi_scopy(name, sizeof name, line ? sub[c] : cols[c].name);
            sb_pad(&b, name, width[c], 0);
            fqi_sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
        }
    for (int c = 0; c < shown; c++) {
        for (int i = 0; i < width[c]; i++)
            fqi_sb_add(&b, "-", 1);
        fqi_sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
    }
    for (int64_t r = 0; r < show; r++)
        for (int c = 0; c < shown; c++) {
            const tcol *t = &cols[c];
            int right = t->type == 'a' ? toupper((unsigned char)t->form[0]) != 'A'
                                       : t->type != 'A' && t->type != 'L';
            sb_pad(&b, cells + (r * shown + c) * (CELL + 1), width[c], right);
            fqi_sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
        }
done:
    free(width);
    free(cells);
    free(sub);
    free(cols);
    if (b.oom) {
        free(b.s);
        return NULL;
    }
    if (len)
        *len = b.len;
    return b.s;
}
