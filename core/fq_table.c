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

#define MAX_COLS 999
#define PLOT_MAX_POINTS ((int64_t)20000000)  /* bigger tables are sampled */
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
static double cell_value(const uint8_t *row, const tcol *t, int64_t e);

/* The point at element e of a row, as plotted; 0 if it is not plotted.
   Sky positions outside the sphere's ranges are placeholders (-999 and
   the like); with wrap, right ascensions above 180 become negative. */
static int plot_point(const fqi_plotspec *ps, const tcol *tx, const tcol *ty, const uint8_t *row,
                      int64_t e, int wrap, double *x, double *y)
{
    *x = cell_value(row, tx, e);
    *y = cell_value(row, ty, e);
    if (ps->xlog)
        *x = pow(10.0, *x);
    if (!isfinite(*x) || !isfinite(*y))
        return 0;
    if (ps->sky) {
        if (*x < -360 || *x > 360 || *y < -90 || *y > 90)
            return 0;
        if (wrap && *x > 180)
            *x -= 360;
    }
    return 1;
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
    const tcol tx = cols[ps.xcol], ty = cols[ps.ycol];
    free(cols);

    int64_t avail = f->size - h->data_off;
    int64_t rows = avail > 0 ? avail / rowlen : 0;
    if (rows > nrows)
        rows = nrows;
    const uint8_t *base = f->data + h->data_off;
    const int64_t rep = ps.repeat, total = fqi_mul_sat(rows, rep);
    const int64_t step = total > PLOT_MAX_POINTS ? total / (PLOT_MAX_POINTS / 2) : 1;
    const int64_t sstep = total / step / STAT_SAMPLES + 1;
    float *samp = malloc((size_t)(total / step / sstep + 2) * sizeof(float));
    if (!samp) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }

    /* Pass 1: x range and a subsample of y for the plot range. For sky
       positions also the range with right ascension in -180...180, which
       is smaller when the field straddles RA = 0. */
    double xmin = INFINITY, xmax = -INFINITY, wmin = INFINITY, wmax = -INFINITY;
    int64_t nvalid = 0, ns = 0;
    for (int64_t k = 0; k < total; k += step) {
        const uint8_t *row = base + (k / rep) * rowlen;
        double x, y;
        if (!plot_point(&ps, &tx, &ty, row, k % rep, 0, &x, &y))
            continue;
        if (x < xmin) xmin = x;
        if (x > xmax) xmax = x;
        double w = x > 180 ? x - 360 : x;
        if (w < wmin) wmin = w;
        if (w > wmax) wmax = w;
        if (nvalid++ % sstep == 0)
            samp[ns++] = (float)y;
    }
    if (!nvalid) {
        free(samp);
        fqi_seterr(err, errlen, "no valid values in %s and %s", ps.xname, ps.yname);
        return -1;
    }
    const int wrap = ps.sky && wmax - wmin < xmax - xmin;
    if (wrap) {
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
    if (!img->spec_lo || !img->spec_hi) {
        free(samp);
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }
    for (int c = 0; c < ncol; c++)
        img->spec_lo[c] = img->spec_hi[c] = NAN;
    fqi_plot_range(samp, ns, &img->y_min, &img->y_max);
    free(samp);

    /* Time series and sky positions are drawn as dots: count the points in
       the cells of a grid, so that sparse and crowded parts both show. */
    int nrow = 0;
    if (ps.points) {
        nrow = ncol * 3 / 4;
        nrow = nrow < 16 ? 16 : nrow > 1024 ? 1024 : nrow;
        img->dots = calloc((size_t)ncol * (size_t)nrow, 1);
        if (!img->dots) {
            fqi_seterr(err, errlen, "out of memory");
            return -1;
        }
        img->dot_rows = nrow;
    }
    const double rowper = nrow / (img->y_max - img->y_min);

    const double span = xmax - xmin, per = ncol > 1 ? ncol / span : 0;
    for (int64_t k = 0; k < total; k += step) {
        const uint8_t *row = base + (k / rep) * rowlen;
        double x, y;
        if (!plot_point(&ps, &tx, &ty, row, k % rep, wrap, &x, &y))
            continue;
        int c = ncol > 1 ? (int)((x - xmin) * per) : 0;
        if (c >= ncol)
            c = ncol - 1;
        if (c < 0)
            c = 0;
        float v = (float)y;
        if (!(v >= img->spec_lo[c]))
            img->spec_lo[c] = v;
        if (!(v <= img->spec_hi[c]))
            img->spec_hi[c] = v;
        if (nrow) {
            double r = (y - img->y_min) * rowper;   /* off the plot: no dot */
            if (r >= 0 && r < nrow) {
                uint8_t *cell = &img->dots[(size_t)c * (size_t)nrow + (size_t)r];
                if (*cell < 255)
                    (*cell)++;
            }
        }
    }

    img->spec_n = ncol;
    img->spec_points = nvalid;
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
    img->x_wrap = wrap;
    if (ps.xlog) {   /* SDSS: log10 of the wavelength in Angstrom */
        fqi_scopy(img->x_label, sizeof img->x_label,
                  islower((unsigned char)ps.xname[0]) ? "wavelength" : "WAVELENGTH");
        fqi_scopy(img->x_unit, sizeof img->x_unit, "Angstrom");
    } else {
        fqi_scopy(img->x_label, sizeof img->x_label, ps.xname);
        fqi_scopy(img->x_unit, sizeof img->x_unit, tx.unit);
    }
    fqi_scopy(img->y_label, sizeof img->y_label, ps.yname);
    fqi_scopy(img->y_unit, sizeof img->y_unit, ty.unit);

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
}

/* ------------------------------------------------------------- listings */

typedef struct {
    char *s;
    size_t len, cap;
    int oom;
} sbuf;

static void sb_add(sbuf *b, const char *s, size_t n)
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

static void sb_printf(sbuf *b, const char *fmt, ...)
{
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n > 0)
        sb_add(b, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
}

static void sb_pad(sbuf *b, const char *s, int width, int right)
{
    int n = (int)strlen(s);
    for (int i = n; right && i < width; i++)
        sb_add(b, " ", 1);
    sb_add(b, s, (size_t)n);
    for (int i = n; !right && i < width; i++)
        sb_add(b, " ", 1);
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

/* One table cell as text, at most CELL characters. */
static void fmt_cell(const uint8_t *row, const tcol *t, char *out)
{
    const size_t n = CELL + 1;
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
        for (int64_t i = a; i < b && k < CELL; i++)
            out[k++] = (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
        out[k] = 0;
        return;
    }
    case 'A': {
        size_t k = 0;
        for (int64_t i = 0; i < t->repeat && p[i] && k < CELL; i++)
            out[k++] = (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
        while (k > 0 && out[k - 1] == ' ')
            k--;
        out[k] = 0;
        return;
    }
    case 'L': {
        size_t k = 0;
        for (int64_t i = 0; i < t->repeat && k + 2 < CELL; i++) {
            out[k++] = p[i] == 'T' ? 'T' : p[i] == 'F' ? 'F' : '-';
            if (i + 1 < t->repeat)
                out[k++] = ' ';
        }
        out[k] = 0;
        return;
    }
    case 'X': {
        size_t k = (size_t)snprintf(out, n, "0x");
        for (int64_t i = 0; i < t->width && k + 2 < CELL; i++)
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
    size_t k = 0;
    out[k++] = '[';
    for (int64_t i = 0; i < t->repeat && i < 3; i++) {
        char v[CELL + 1];
        fmt_number(row, t, i, v, sizeof v);
        size_t vl = strlen(v);
        if (k + vl + 6 > CELL)
            break;
        if (i)
            out[k++] = ' ';
        memcpy(out + k, v, vl);
        k += vl;
    }
    if (t->repeat > 3 && k + 4 <= CELL) {
        memcpy(out + k, " ...", 4);
        k += 4;
    }
    out[k++] = ']';
    out[k] = 0;
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
    sbuf b = { 0 };
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
            fmt_cell(base + r * rowlen, &cols[c], cell);
            int w = (int)strlen(cell);
            if (w > width[c])
                width[c] = w;
        }
    sb_printf(&b, "%lld rows x %d columns", (long long)nrows, nc);
    if (show < nrows)
        sb_printf(&b, ", first %lld rows", (long long)show);
    if (shown < nc)
        sb_printf(&b, ", first %d columns", shown);
    sb_add(&b, "\n\n", 2);
    for (int line = 0; line < 2; line++)
        for (int c = 0; c < shown; c++) {
            char name[CELL + 1];
            fqi_scopy(name, sizeof name, line ? sub[c] : cols[c].name);
            sb_pad(&b, name, width[c], 0);
            sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
        }
    for (int c = 0; c < shown; c++) {
        for (int i = 0; i < width[c]; i++)
            sb_add(&b, "-", 1);
        sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
    }
    for (int64_t r = 0; r < show; r++)
        for (int c = 0; c < shown; c++) {
            const tcol *t = &cols[c];
            int right = t->type == 'a' ? toupper((unsigned char)t->form[0]) != 'A'
                                       : t->type != 'A' && t->type != 'L';
            sb_pad(&b, cells + (r * shown + c) * (CELL + 1), width[c], right);
            sb_add(&b, c + 1 < shown ? "  " : "\n", c + 1 < shown ? 2 : 1);
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
