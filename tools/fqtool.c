/*
 * fqtool - command line front end to the uFits core.
 *
 *   fqtool info FILE                 HDU list and what would be shown
 *   fqtool hdus FILE                 the HDUs a viewer can switch between
 *   fqtool header FILE [HDU] [--raw|--cards|--spans]   header cards lined up
 *                                     as the preview shows them (or as in the
 *                                     file, split by tabs, or the styled parts)
 *   fqtool table FILE HDU [ROWS]     columns and first rows of a table
 *   fqtool render FILE OUT.png [options]
 *   fqtool dump FILE OUT.f32 [options]   binned float32 values (tests)
 *   fqtool plot FILE OUT [options]   plot envelope, low then high, then
 *                                     the dot grid of time series (tests)
 *   fqtool rows FILE HDU FIRST COUNT  table cells, tab separated (tests)
 *
 * Options: --max N  --samples K  --stretch auto|linear|minmax  --hdu N
 *          --plane P  --mono  --threads T  --repeat R
 *          --then auto|linear|minmax   restretch after rendering (tests)
 *          --region X,Y,W,H  render: only these pixels (from the first of
 *                            the first row), with the whole image's stretch
 *                            as the preview's zoom does
 */
#define _POSIX_C_SOURCE 200809L
#include "fq.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void put32(FILE *fp, uint32_t v)
{
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(b, 1, 4, fp);
}

static void chunk(FILE *fp, const char *type, const uint8_t *data, uint32_t len)
{
    put32(fp, len);
    fwrite(type, 1, 4, fp);
    if (len)
        fwrite(data, 1, len, fp);
    uLong crc = crc32(0, (const Bytef *)type, 4);
    if (len)
        crc = crc32(crc, data, len);
    put32(fp, (uint32_t)crc);
}

static int write_png(const char *path, const uint8_t *px, int w, int h, int comps, size_t stride)
{
    size_t rowlen = (size_t)w * comps, rawlen = (rowlen + 1) * h;
    uint8_t *raw = malloc(rawlen);
    uLongf clen = compressBound(rawlen);
    uint8_t *cbuf = malloc(clen);
    if (!raw || !cbuf)
        return -1;
    for (int y = 0; y < h; y++) {
        raw[y * (rowlen + 1)] = 0;
        memcpy(raw + y * (rowlen + 1) + 1, px + y * stride, rowlen);
    }
    compress2(cbuf, &clen, raw, rawlen, 6);
    FILE *fp = fopen(path, "wb");
    if (!fp)
        return -1;
    static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    fwrite(sig, 1, 8, fp);
    uint8_t ihdr[13] = { 0 };
    ihdr[0] = (uint8_t)(w >> 24); ihdr[1] = (uint8_t)(w >> 16); ihdr[2] = (uint8_t)(w >> 8); ihdr[3] = (uint8_t)w;
    ihdr[4] = (uint8_t)(h >> 24); ihdr[5] = (uint8_t)(h >> 16); ihdr[6] = (uint8_t)(h >> 8); ihdr[7] = (uint8_t)h;
    ihdr[8] = 8;
    ihdr[9] = comps == 1 ? 0 : 6;
    chunk(fp, "IHDR", ihdr, 13);
    chunk(fp, "IDAT", cbuf, (uint32_t)clen);
    chunk(fp, "IEND", NULL, 0);
    fclose(fp);
    free(raw);
    free(cbuf);
    return 0;
}

/* Draw a spectrum envelope into a gray image, for eyeballing. */
static int write_spectrum_png(const char *path, const fq_image *img)
{
    int w = img->spec_n < 1200 ? 1200 : img->spec_n, h = 500;
    uint8_t *px = malloc((size_t)w * h);
    if (!px)
        return -1;
    memset(px, 255, (size_t)w * h);
    double lo = img->y_min, hi = img->y_max;
    if (img->y_flip) {   /* magnitudes: small values on top */
        lo = img->y_max;
        hi = img->y_min;
    }
    if (img->dots) {   /* points: the grid, darker where it is crowded */
        for (int c = 0; c < img->spec_n; c++)
            for (int r = 0; r < img->dot_rows; r++) {
                int k = img->dots[(size_t)c * img->dot_rows + r];
                if (!k)
                    continue;
                uint8_t ink = (uint8_t)(k >= 16 ? 0 : 160 - 10 * k);
                int x = (int)((int64_t)c * (w - 2) / img->spec_n);
                int y = (int)((int64_t)r * (h - 2) / img->dot_rows);
                if (img->x_flip)
                    x = w - 2 - x;
                if (!img->y_flip)
                    y = h - 2 - y;
                for (int dy = 0; dy < 2; dy++)
                    for (int dx = 0; dx < 2; dx++)
                        if (px[(size_t)(y + dy) * w + x + dx] > ink)
                            px[(size_t)(y + dy) * w + x + dx] = ink;
            }
        int rc = write_png(path, px, w, h, 1, (size_t)w);
        free(px);
        return rc;
    }
    int prev = -1;
    for (int x = 0; x < w; x++) {
        int c = (int)((int64_t)x * img->spec_n / w);
        float a = img->spec_lo[c], b = img->spec_hi[c];
        if (!(a == a))
            continue;
        if (img->y_flip) {
            float t = a;
            a = b;
            b = t;
        }
        double fy0 = (hi - b) / (hi - lo) * (h - 1), fy1 = (hi - a) / (hi - lo) * (h - 1);
        double fmid = (hi - ((double)a + b) / 2) / (hi - lo) * (h - 1);
        int y0 = fy0 < 0 ? 0 : fy0 > h - 1 ? h - 1 : (int)fy0;
        int y1 = fy1 < 0 ? 0 : fy1 > h - 1 ? h - 1 : (int)fy1;
        if (prev >= 0) {
            if (prev < y0) y0 = prev;
            if (prev > y1) y1 = prev;
        }
        prev = fmid < 0 ? 0 : fmid > h - 1 ? h - 1 : (int)fmid;
        for (int y = y0; y <= y1; y++)
            if (y >= 0 && y < h)
                px[(size_t)y * w + x] = 0;
    }
    int rc = write_png(path, px, w, h, 1, (size_t)w);
    free(px);
    return rc;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: fqtool info FILE\n"
            "       fqtool hdus FILE\n"
            "       fqtool header FILE [HDU] [--raw|--cards|--spans]\n"
            "       fqtool table FILE HDU [ROWS]\n"
            "       fqtool render FILE OUT.png [--max N] [--samples K] [--stretch auto|linear|minmax]\n"
            "                                 [--hdu N] [--plane P] [--mono] [--threads T] [--repeat R]\n"
            "                                 [--region X,Y,W,H]\n"
            "       fqtool dump FILE OUT.f32 [same options]\n"
            "       fqtool plot FILE OUT.f32 [same options]\n"
            "       fqtool rows FILE HDU FIRST COUNT\n");
}

static int stretch_named(const char *v)
{
    return !strcmp(v, "linear") ? FQ_STRETCH_LINEAR : !strcmp(v, "minmax") ? FQ_STRETCH_MINMAX : FQ_STRETCH_AUTO;
}

static int then_stretch = -1;   /* --then: restretch after rendering */

static int parse_opts(int argc, char **argv, int start, fq_opts *o, int *repeat)
{
    for (int i = start; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--mono")) {
            o->mono = 1;
            continue;
        }
        if (!v) {
            fprintf(stderr, "missing value for %s\n", a);
            return -1;
        }
        i++;
        if (!strcmp(a, "--max"))
            o->max_width = o->max_height = atoi(v);
        else if (!strcmp(a, "--samples"))
            o->max_samples = atoi(v);
        else if (!strcmp(a, "--hdu"))
            o->hdu = atoi(v);
        else if (!strcmp(a, "--plane"))
            o->plane = atoi(v);
        else if (!strcmp(a, "--threads"))
            o->threads = atoi(v);
        else if (!strcmp(a, "--repeat"))
            *repeat = atoi(v);
        else if (!strcmp(a, "--stretch"))
            o->stretch = stretch_named(v);
        else if (!strcmp(a, "--then"))
            then_stretch = stretch_named(v);
        else if (!strcmp(a, "--region")) {
            long long r[4];
            if (sscanf(v, "%lld,%lld,%lld,%lld", &r[0], &r[1], &r[2], &r[3]) != 4) {
                fprintf(stderr, "--region wants X,Y,W,H\n");
                return -1;
            }
            for (int k = 0; k < 4; k++)
                o->region[k] = r[k];
        } else {
            fprintf(stderr, "unknown option %s\n", a);
            return -1;
        }
    }
    return 0;
}

static void print_info(const fq_info *in)
{
    printf("hdu=%d extname=%s kind=%d bitpix=%d naxis=%d dims=", in->hdu, in->extname,
           in->kind, in->bitpix, in->naxis);
    for (int i = 0; i < in->naxis; i++)
        printf(i ? "x%lld" : "%lld", (long long)in->naxes[i]);
    printf(" compressed=%d%s%s plane=%lld/%lld color=%d bayer=%s bin=%d samples=%d out=%dx%d"
           " flipped=%d truncated=%d empty=%d table=%d median=%.6g sigma=%.6g black=%.6g white=%.6g"
           " region=%lld,%lld,%lld,%lld\n",
           in->compressed, in->compressed ? ":" : "", in->cmptype, (long long)in->plane,
           (long long)in->nplanes, in->color, in->bayer, in->bin, in->samples, in->width,
           in->height, in->flipped, in->truncated, in->empty, in->table, in->median, in->sigma,
           in->black, in->white, (long long)in->region[0], (long long)in->region[1],
           (long long)in->region[2], (long long)in->region[3]);
}

/* Everything about a plot, one key=value per line (values may hold spaces). */
static void print_plot(const fq_image *img)
{
    printf("n=%d\npoints=%lld\ny_min=%.17g\ny_max=%.17g\nhas_x=%d\nx_first=%.17g\nx_last=%.17g\n"
           "x_log=%d\nx_flip=%d\nx_wrap=%d\ny_flip=%d\ndots=%d\ndot_rows=%d\nx_label=%s\n"
           "y_label=%s\nx_unit=%s\ny_unit=%s\n",
           img->spec_n, (long long)img->spec_points, img->y_min, img->y_max, img->has_x,
           img->x_first, img->x_last, img->x_log, img->x_flip, img->x_wrap, img->y_flip,
           img->points, img->dot_rows, img->x_label, img->y_label, img->x_unit, img->y_unit);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        usage();
        return 2;
    }
    const char *cmd = argv[1], *path = argv[2];
    char err[256] = "";
    double t0 = now_ms();
    fq_file *f = fq_open(path, err, sizeof err);
    if (!f) {
        fprintf(stderr, "%s: %s\n", path, err);
        return 1;
    }
    int rc = 0;
    if (!strcmp(cmd, "info")) {
        char *s = fq_summary_text(f);
        fputs(s ? s : "", stdout);
        free(s);
        fq_opts o;
        fq_opts_default(&o);
        fq_image *img = fq_render(f, &o, err, sizeof err);
        if (img) {
            print_info(&img->info);
            fq_image_free(img);
        } else {
            printf("no image: %s\n", err);
        }
    } else if (!strcmp(cmd, "hdus")) {
        fq_hdu_entry e[64];
        int n = fq_list_hdus(f, e, 64);
        for (int i = 0; i < n; i++)
            printf("%d %s %lld %s | %s\n", e[i].hdu,
                   e[i].kind == FQ_KIND_PLOT    ? "plot"
                   : e[i].kind == FQ_KIND_TABLE ? "table"
                                                : "image",
                   (long long)e[i].nplanes, e[i].extname[0] ? e[i].extname : "-", e[i].desc);
    } else if (!strcmp(cmd, "rows")) {
        int hdu = argc > 3 ? atoi(argv[3]) : 1;
        long long first = argc > 4 ? atoll(argv[4]) : 0, count = argc > 5 ? atoll(argv[5]) : 10;
        fq_table *t = fq_table_open(f, hdu);
        if (!t) {
            fprintf(stderr, "HDU %d is not a table\n", hdu);
            rc = 1;
        } else {
            int nc = fq_table_ncols(t);
            printf("rows=%lld cols=%d\n", (long long)fq_table_rows(t), nc);
            for (int c = 0; c < nc; c++)
                printf("%s%s", c ? "\t" : "", fq_table_column(t, c)->name);
            printf("\n");
            for (long long r = first; r < first + count; r++) {
                char cell[200];
                for (int c = 0; c < nc; c++) {
                    fq_table_cell(t, r, c, cell, sizeof cell);
                    printf("%s%s", c ? "\t" : "", cell);
                }
                printf("\n");
            }
            fq_table_close(t);
        }
    } else if (!strcmp(cmd, "table")) {
        int hdu = argc > 3 ? atoi(argv[3]) : 1, rows = argc > 4 ? atoi(argv[4]) : 20;
        char *s = fq_table_text(f, hdu, rows, NULL);
        if (!s) {
            fprintf(stderr, "HDU %d is not a table\n", hdu);
            rc = 1;
        } else {
            fputs(s, stdout);
            free(s);
        }
    } else if (!strcmp(cmd, "header")) {
        int hdu = 0;
        const char *how = "";
        for (int i = 3; i < argc; i++) {
            if (!strncmp(argv[i], "--", 2))
                how = argv[i] + 2;
            else
                hdu = atoi(argv[i]);
        }
        fq_span *spans = NULL;
        size_t nspans = 0;
        char *s = !strcmp(how, "raw")     ? fq_header_text(f, hdu, NULL)
                : !strcmp(how, "cards")   ? fq_header_cards(f, hdu, NULL)
                                          : fq_header_layout(f, hdu, NULL, &spans, &nspans);
        if (!s) {
            fprintf(stderr, "no HDU %d\n", hdu);
            rc = 1;
        } else if (!strcmp(how, "spans")) {
            for (size_t i = 0; i < nspans; i++)
                printf("%d %u %u\n", spans[i].kind, spans[i].start, spans[i].len);
        } else {
            fputs(s, stdout);
        }
        free(s);
        free(spans);
    } else if (!strcmp(cmd, "render") || !strcmp(cmd, "dump") || !strcmp(cmd, "plot")) {
        if (argc < 4) {
            usage();
            fq_close(f);
            return 2;
        }
        fq_opts o;
        fq_opts_default(&o);
        int repeat = 1;
        if (parse_opts(argc, argv, 4, &o, &repeat) != 0) {
            fq_close(f);
            return 2;
        }
        if (!strcmp(cmd, "plot")) {
            fq_image *img = fq_render(f, &o, err, sizeof err);
            if (!img) {
                fprintf(stderr, "%s: %s\n", path, err);
                rc = 1;
            } else if (img->info.kind != FQ_KIND_PLOT) {
                fprintf(stderr, "%s: not a plot\n", path);
                fq_image_free(img);
                rc = 1;
            } else {
                FILE *fp = fopen(argv[3], "wb");
                if (fp) {
                    fwrite(img->spec_lo, sizeof(float), (size_t)img->spec_n, fp);
                    fwrite(img->spec_hi, sizeof(float), (size_t)img->spec_n, fp);
                    if (img->dots)
                        fwrite(img->dots, 1, (size_t)img->spec_n * (size_t)img->dot_rows, fp);
                    fclose(fp);
                }
                print_info(&img->info);
                print_plot(img);
                fq_image_free(img);
            }
        } else if (!strcmp(cmd, "dump")) {
            o.exact = 1;
            int w, h, nch;
            fq_info info;
            float *v = fq_decode_float(f, &o, &w, &h, &nch, &info, err, sizeof err);
            if (!v) {
                fprintf(stderr, "%s: %s\n", path, err);
                rc = 1;
            } else {
                FILE *fp = fopen(argv[3], "wb");
                fwrite(v, sizeof(float), (size_t)w * h * nch, fp);
                fclose(fp);
                printf("%d %d %d\n", w, h, nch);
                print_info(&info);
                free(v);
            }
        } else {
            double best = 1e30, t_open = now_ms() - t0;
            fq_image *img = NULL;
            o.keep = then_stretch >= 0;
            int64_t region[4];
            memcpy(region, o.region, sizeof region);
            int detail = region[2] > 0 && region[3] > 0;
            memset(o.region, 0, sizeof o.region);
            for (int r = 0; r < (repeat < 1 ? 1 : repeat); r++) {
                if (img)
                    fq_image_free(img);
                double t1 = now_ms();
                img = fq_render(f, &o, err, sizeof err);
                if (img && detail && img->info.kind == FQ_KIND_IMAGE) {
                    fq_opts d = o;
                    memcpy(d.region, region, sizeof region);
                    /* The plane shown (the middle one of a cube, say); an
                       RGB cube is asked for as a whole. */
                    d.plane = img->info.color == FQ_COLOR_RGB ? -1 : (int)img->info.plane;
                    fq_image *part = fq_render_detail(f, &d, &img->stretch, err, sizeof err);
                    fq_image_free(img);
                    img = part;
                }
                double dt = now_ms() - t1;
                if (dt < best)
                    best = dt;
                if (!img)
                    break;
            }
            if (img && then_stretch >= 0) {
                double t1 = now_ms();
                if (fq_restretch(img, then_stretch, o.threads) != 0)
                    fprintf(stderr, "%s: cannot restretch\n", path);
                printf("restretch %.2f ms\n", now_ms() - t1);
            }
            if (!img) {
                fprintf(stderr, "%s: %s\n", path, err);
                rc = 1;
            } else {
                print_info(&img->info);
                printf("open %.2f ms, render %.2f ms (best of %d)\n", t_open, best, repeat);
                if (img->info.kind == FQ_KIND_PLOT) {
                    printf("plot n=%d points=%lld y=[%g, %g] x=%d [%g, %g] log=%d xflip=%d wrap=%d"
                           " flip=%d dots=%d %s [%s] vs %s [%s]\n",
                           img->spec_n, (long long)img->spec_points, img->y_min, img->y_max,
                           img->has_x, img->x_first, img->x_last, img->x_log, img->x_flip,
                           img->x_wrap, img->y_flip, img->points, img->y_label, img->y_unit,
                           img->x_label, img->x_unit);
                    write_spectrum_png(argv[3], img);
                } else {
                    /* Output statistics: median grey of the opaque pixels and
                       the transparent fraction, for tests of the stretch. */
                    size_t npx = (size_t)img->width * img->height, nop = 0;
                    unsigned long hist[256] = { 0 };
                    for (int y = 0; y < img->height; y++)
                        for (int x = 0; x < img->width; x++) {
                            const uint8_t *p = img->pixels + y * img->row_bytes + x * img->components;
                            if (img->components == 4 && p[3] == 0)
                                continue;
                            hist[p[0]]++;
                            nop++;
                        }
                    int med = 0;
                    for (unsigned long acc = 0; med < 255 && (acc += hist[med]) * 2 < nop; med++)
                        ;
                    printf("output median=%d transparent=%.4f\n", nop ? med : -1,
                           npx ? 1.0 - (double)nop / (double)npx : 0.0);
                    write_png(argv[3], img->pixels, img->width, img->height, img->components,
                              img->row_bytes);
                }
                fq_image_free(img);
            }
        }
    } else {
        usage();
        rc = 2;
    }
    fq_close(f);
    return rc;
}
