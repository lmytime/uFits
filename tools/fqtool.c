/*
 * fqtool - command line front end to the uFits core.
 *
 *   fqtool info FILE                 HDU list and what would be shown
 *   fqtool header FILE [HDU]         header cards
 *   fqtool render FILE OUT.png [options]
 *   fqtool dump FILE OUT.f32 [options]   binned float32 values (tests)
 *
 * Options: --max N  --samples K  --stretch auto|linear|minmax  --hdu N
 *          --plane P  --mono  --threads T  --repeat R
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
    int prev = -1;
    for (int x = 0; x < w; x++) {
        int c = (int)((int64_t)x * img->spec_n / w);
        float a = img->spec_lo[c], b = img->spec_hi[c];
        if (!(a == a))
            continue;
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
            "       fqtool header FILE [HDU]\n"
            "       fqtool render FILE OUT.png [--max N] [--samples K] [--stretch auto|linear|minmax]\n"
            "                                 [--hdu N] [--plane P] [--mono] [--threads T] [--repeat R]\n"
            "       fqtool dump FILE OUT.f32 [same options]\n");
}

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
            o->stretch = !strcmp(v, "linear") ? FQ_STRETCH_LINEAR
                       : !strcmp(v, "minmax") ? FQ_STRETCH_MINMAX : FQ_STRETCH_AUTO;
        else {
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
           " flipped=%d truncated=%d median=%.6g sigma=%.6g black=%.6g white=%.6g\n",
           in->compressed, in->compressed ? ":" : "", in->cmptype, (long long)in->plane,
           (long long)in->nplanes, in->color, in->bayer, in->bin, in->samples, in->width,
           in->height, in->flipped, in->truncated, in->median, in->sigma, in->black, in->white);
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
    } else if (!strcmp(cmd, "header")) {
        int hdu = argc > 3 ? atoi(argv[3]) : 0;
        char *s = fq_header_text(f, hdu, NULL);
        if (!s) {
            fprintf(stderr, "no HDU %d\n", hdu);
            rc = 1;
        } else {
            fputs(s, stdout);
            free(s);
        }
    } else if (!strcmp(cmd, "render") || !strcmp(cmd, "dump")) {
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
        if (!strcmp(cmd, "dump")) {
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
            for (int r = 0; r < (repeat < 1 ? 1 : repeat); r++) {
                if (img)
                    fq_image_free(img);
                double t1 = now_ms();
                img = fq_render(f, &o, err, sizeof err);
                double dt = now_ms() - t1;
                if (dt < best)
                    best = dt;
                if (!img)
                    break;
            }
            if (!img) {
                fprintf(stderr, "%s: %s\n", path, err);
                rc = 1;
            } else {
                print_info(&img->info);
                printf("open %.2f ms, render %.2f ms (best of %d)\n", t_open, best, repeat);
                if (img->info.kind == FQ_KIND_SPECTRUM) {
                    printf("spectrum n=%d points=%lld y=[%g, %g] x=%d [%g, %g] log=%d xunit=%s yunit=%s\n",
                           img->spec_n, (long long)img->spec_points, img->y_min, img->y_max,
                           img->has_x, img->x_first, img->x_last, img->x_log, img->x_unit,
                           img->y_unit);
                    write_spectrum_png(argv[3], img);
                } else {
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
