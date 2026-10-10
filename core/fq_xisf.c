/* Native, read-only XISF 1.0 image support. XML metadata is bounded and
   parsed eagerly; only the selected image's pixels are decoded. */
#include "fq_internal.h"
#include "zstd.h"
#include <expat.h>
#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#define X_HEADER_LIMIT (16u << 20)
#define X_DECODE_LIMIT ((size_t)512 << 20)
#define X_IMAGES_LIMIT 1024
#define X_SUBBLOCK_LIMIT 65536
#define X_TEXT_LIMIT (1u << 20)

enum { X_RAW, X_ZLIB, X_LZ4, X_ZSTD };
typedef struct { size_t stored, raw; } xblock;
struct fqi_xisf_image {
    int big, normal, channels, codec, shuffle, embedded, have_data, have_cfa;
    int encoding;                 /* 1 = base64, 2 = hex */
    size_t stored, raw, offset, declared;
    xblock *blocks;
    size_t nblocks;
    char type[24], compression[24], bayer[8], error[160];
    fqi_sbuf cards, encoded;
    uint8_t *decoded;
};
typedef struct {
    fq_file *f;
    XML_Parser parser;
    int depth, image_depth, data_depth, property_depth, failed, root;
    hdu_t *h;
    char property[256];
    fqi_sbuf text;
    char *err;
    size_t errlen, header_end;
} xparser;

static const char *attr(const XML_Char **a, const char *key)
{
    for (; a && *a; a += 2)
        if (!strcmp(a[0], key))
            return a[1];
    return NULL;
}

/* Only core elements, in the standard namespace or legacy unqualified XML. */
static const char *element(const char *name)
{
    const char *sep = strchr(name, '|');
    if (!sep)
        return name;
    static const char ns[] = "http://www.pixinsight.com/xisf";
    return (size_t)(sep - name) == sizeof ns - 1 && !memcmp(name, ns, sizeof ns - 1)
        ? sep + 1 : "";
}

static void fail(xparser *p, const char *message)
{
    if (!p->failed)
        fqi_seterr(p->err, p->errlen, "XISF: %s", message);
    p->failed = 1;
    XML_StopParser(p->parser, XML_FALSE);
}

static void unsupported(fqi_xisf_image *x, const char *message)
{
    if (!x->error[0])
        fqi_scopy(x->error, sizeof x->error, message);
}

static int number(const char **s, size_t *n)
{
    if (!*s || !isdigit((unsigned char)**s))
        return 0;
    size_t v = 0;
    do {
        unsigned digit = (unsigned)(*(*s)++ - '0');
        if (v > (SIZE_MAX - digit) / 10)
            return 0;
        v = v * 10 + digit;
    } while (isdigit((unsigned char)**s));
    *n = v;
    return 1;
}

static void clean(fqi_sbuf *b, const char *s)
{
    for (; s && *s; s++) {
        unsigned char ch = (unsigned char)*s;
        char c = ch < 32 ? ' ' : ch >= 127 ? '?' : (char)ch;
        fqi_sb_add(b, &c, 1);
    }
}

static void card(fqi_xisf_image *x, const char *key, const char *value, const char *comment)
{
    fqi_sb_add(&x->cards, "v\t", 2);
    clean(&x->cards, key);
    fqi_sb_add(&x->cards, "\t", 1);
    clean(&x->cards, value);
    fqi_sb_add(&x->cards, "\t", 1);
    clean(&x->cards, comment);
    fqi_sb_add(&x->cards, "\n", 1);
}

static void compression(xparser *p, fqi_xisf_image *x, const XML_Char **a)
{
    const char *s = attr(a, "compression"), *sub = attr(a, "subblocks");
    if (!s) {
        if (sub)
            fail(p, "subblocks requires compression");
        return;
    }
    const char *colon = strchr(s, ':');
    if (!colon || (size_t)(colon - s) >= sizeof x->compression) {
        fail(p, "invalid compression declaration");
        return;
    }
    memcpy(x->compression, s, (size_t)(colon - s));
    x->compression[colon - s] = 0;
    char codec[24];
    fqi_scopy(codec, sizeof codec, x->compression);
    char *sh = strstr(codec, "+sh");
    int shuffled = sh && !sh[3];
    if (shuffled)
        *sh = 0;
    if (!strcmp(codec, "zlib")) x->codec = X_ZLIB;
    else if (!strcmp(codec, "lz4") || !strcmp(codec, "lz4hc")) x->codec = X_LZ4;
    else if (!strcmp(codec, "zstd")) x->codec = X_ZSTD;
    else {
        unsupported(x, "unsupported XISF compression codec");
        return; /* Parameters of an unknown codec are codec-specific. */
    }
    s = colon + 1;
    if (!number(&s, &x->declared) || !x->declared) {
        fail(p, "invalid uncompressed block size");
        return;
    }
    if (shuffled) {
        size_t item;
        if (*s++ != ':' || !number(&s, &item) || item < 1 || item > 1024) {
            fail(p, "invalid byte-shuffle item size");
            return;
        }
        x->shuffle = (int)item;
    }
    if (*s) {
        fail(p, "invalid compression parameters");
        return;
    }
    if (!sub)
        return;
    size_t cap = 0;
    s = sub;
    do {
        xblock b;
        if (!number(&s, &b.stored) || *s++ != ',' || !number(&s, &b.raw) ||
            !b.stored || !b.raw || x->nblocks == X_SUBBLOCK_LIMIT) {
            fail(p, "invalid compression subblocks");
            return;
        }
        if (x->nblocks == cap) {
            cap = cap ? cap * 2 : 8;
            xblock *v = realloc(x->blocks, cap * sizeof *v);
            if (!v) { fail(p, "out of memory"); return; }
            x->blocks = v;
        }
        x->blocks[x->nblocks++] = b;
        if (!*s)
            break;
        if (*s++ != ':' || !*s) { fail(p, "invalid compression subblocks"); return; }
    } while (*s);
}

static void image_start(xparser *p, const XML_Char **a)
{
    if (p->f->nhdu == X_IMAGES_LIMIT) { fail(p, "too many images"); return; }
    if (p->f->nhdu == p->f->hcap) {
        int cap = p->f->hcap ? p->f->hcap * 2 : 8;
        hdu_t *v = realloc(p->f->hdu, (size_t)cap * sizeof *v);
        if (!v) { fail(p, "out of memory"); return; }
        p->f->hdu = v;
        p->f->hcap = cap;
    }
    hdu_t *h = &p->f->hdu[p->f->nhdu++];
    memset(h, 0, sizeof *h);
    h->bscale = 1;
    h->gcount = 1;
    fqi_scopy(h->xtension, sizeof h->xtension, "IMAGE");
    fqi_xisf_image *x = h->xisf = calloc(1, sizeof *x);
    if (!x) { fail(p, "out of memory"); return; }
    p->h = h;
    p->image_depth = p->depth;
    const char *s = attr(a, "geometry");
    size_t dims[FQ_MAXAXES + 1];
    int nd = 0;
    if (!s) { fail(p, "missing image geometry"); return; }
    do {
        if (nd == FQ_MAXAXES + 1 || !number(&s, &dims[nd]) ||
            !dims[nd] || dims[nd] > ((size_t)1 << 28)) {
            fail(p, "invalid image geometry"); return;
        }
        nd++;
        if (!*s) break;
        if (*s++ != ':' || !*s) { fail(p, "invalid image geometry"); return; }
    } while (*s);
    if (nd < 2) { fail(p, "invalid image geometry"); return; }
    x->channels = (int)dims[nd - 1];
    h->naxis = nd - 1;
    for (int i = 0; i < h->naxis; i++)
        h->naxes[i] = (int64_t)dims[i];
    if (nd != 3)
        unsupported(x, "only two-dimensional XISF images are supported");
    if (x->channels > 1 && h->naxis < FQ_MAXAXES)
        h->naxes[h->naxis++] = x->channels;
    s = attr(a, "sampleFormat");
    if (!s) { fail(p, "missing sampleFormat"); return; }
    fqi_scopy(x->type, sizeof x->type, s);
    if (!strcmp(s, "UInt8")) h->bitpix = 8;
    else if (!strcmp(s, "UInt16")) h->bitpix = 16;
    else if (!strcmp(s, "UInt32")) h->bitpix = 32;
    else if (!strcmp(s, "UInt64")) h->bitpix = 64;
    else if (!strcmp(s, "Float32")) h->bitpix = -32;
    else if (!strcmp(s, "Float64")) h->bitpix = -64;
    else unsupported(x, "unsupported XISF sample format");
    size_t bytes = (size_t)abs(h->bitpix) / 8;
    for (int i = 0; i < nd; i++) {
        if (bytes > (size_t)INT64_MAX / dims[i]) { fail(p, "image size overflows"); return; }
        bytes *= dims[i];
    }
    x->raw = bytes;
    h->data_len = (int64_t)bytes;
    s = attr(a, "colorSpace");
    if ((!s || !strcmp(s, "Gray")) ? x->channels != 1 :
        strcmp(s, "RGB") || x->channels != 3)
        unsupported(x, "unsupported XISF color space or channel count");
    s = attr(a, "pixelStorage");
    if (s && strcmp(s, "Planar") && strcmp(s, "Normal"))
        unsupported(x, "unsupported XISF pixel storage");
    x->normal = s && !strcmp(s, "Normal");
    s = attr(a, "byteOrder");
    if (s && strcmp(s, "little") && strcmp(s, "big"))
        unsupported(x, "unsupported XISF byte order");
    x->big = s && !strcmp(s, "big");
    s = attr(a, "orientation");
    if (s && strcmp(s, "0"))
        unsupported(x, "unsupported XISF orientation");
    s = attr(a, "id");
    if (s) fqi_scopy(h->extname, sizeof h->extname, s);
    s = attr(a, "location");
    if (!s) { fail(p, "missing image data location"); return; }
    if (!strcmp(s, "embedded")) {
        x->embedded = 1;
        if (attr(a, "compression") || attr(a, "subblocks"))
            fail(p, "embedded compression belongs to the Data element");
    } else if (!strncmp(s, "attachment:", 11)) {
        s += 11;
        if (!number(&s, &x->offset) || *s++ != ':' || !number(&s, &x->stored) || *s ||
            x->offset < p->header_end || x->offset > (size_t)p->f->size ||
            x->stored > (size_t)p->f->size - x->offset) {
            fail(p, "image attachment is outside the file"); return;
        }
        x->have_data = 1;
        h->data_off = (int64_t)x->offset;
        compression(p, x, a);
    } else {
        unsupported(x, "unsupported XISF image data location");
    }
    for (; *a; a += 2)
        card(x, a[0], a[1], "XISF Image");
}

static void XMLCALL start(void *ctx, const XML_Char *name, const XML_Char **a)
{
    xparser *p = ctx;
    const char *tag = element(name);
    if (++p->depth > 64) { fail(p, "XML nesting is too deep"); return; }
    if (p->depth == 1) {
        const char *v = attr(a, "version");
        if (strcmp(tag, "xisf") || !v || strcmp(v, "1.0")) {
            fail(p, "unsupported XISF XML root or version"); return;
        }
        p->root = 1;
        return;
    }
    if (p->data_depth) { fail(p, "Data cannot contain child elements"); return; }
    if (p->depth == 2 && !strcmp(tag, "Image")) {
        image_start(p, a);
        return;
    }
    if (!p->h || p->depth != p->image_depth + 1)
        return;
    fqi_xisf_image *x = p->h->xisf;
    if (!strcmp(tag, "Data") && x->embedded) {
        if (x->have_data) { fail(p, "duplicate image Data element"); return; }
        x->have_data = 1;
        p->data_depth = p->depth;
        const char *s = attr(a, "encoding");
        if (s && !strcmp(s, "base64")) x->encoding = 1;
        else if (s && !strcmp(s, "hex")) x->encoding = 2;
        else unsupported(x, "unsupported embedded XISF encoding");
        s = attr(a, "byteOrder");
        if (s && strcmp(s, "little") && strcmp(s, "big"))
            unsupported(x, "unsupported XISF byte order");
        x->big = s && !strcmp(s, "big");
        compression(p, x, a);
        for (; *a; a += 2) {
            char key[128];
            snprintf(key, sizeof key, "Data:%s", a[0]);
            card(x, key, a[1], "XISF Data");
        }
    } else if (!strcmp(tag, "FITSKeyword")) {
        const char *key = attr(a, "name"), *value = attr(a, "value");
        if (key) card(x, key, value ? value : "", attr(a, "comment"));
    } else if (!strcmp(tag, "Property")) {
        const char *id = attr(a, "id"), *value = attr(a, "value");
        if (id && value)
            card(x, id, value, attr(a, "type"));
        else if (id && !attr(a, "location")) {
            fqi_scopy(p->property, sizeof p->property, id);
            p->property_depth = p->depth;
            free(p->text.s);
            memset(&p->text, 0, sizeof p->text);
        }
    } else if (!strcmp(tag, "ColorFilterArray")) {
        x->have_cfa = 1;
        const char *pattern = attr(a, "pattern"), *w = attr(a, "width"), *h = attr(a, "height");
        if (pattern) card(x, "ColorFilterArray", pattern, attr(a, "name"));
        if (pattern && w && h && !strcmp(w, "2") && !strcmp(h, "2") &&
            (!strcmp(pattern, "RGGB") || !strcmp(pattern, "BGGR") ||
             !strcmp(pattern, "GRBG") || !strcmp(pattern, "GBRG")))
            fqi_scopy(x->bayer, sizeof x->bayer, pattern);
        /* Other mosaics are displayed as monochrome raw samples. */
    }
}

static void XMLCALL chars(void *ctx, const XML_Char *s, int n)
{
    xparser *p = ctx;
    if (p->data_depth && p->depth == p->data_depth) {
        fqi_sbuf *b = &p->h->xisf->encoded;
        if ((size_t)n > X_HEADER_LIMIT - b->len) { fail(p, "embedded data is too large"); return; }
        fqi_sb_add(b, s, (size_t)n);
        if (b->oom) fail(p, "out of memory");
    } else if (p->property_depth && p->depth == p->property_depth) {
        if ((size_t)n > X_TEXT_LIMIT - p->text.len) { fail(p, "property text is too large"); return; }
        fqi_sb_add(&p->text, s, (size_t)n);
        if (p->text.oom) fail(p, "out of memory");
    }
}

static void XMLCALL end(void *ctx, const XML_Char *name)
{
    (void)name;
    xparser *p = ctx;
    if (p->property_depth == p->depth) {
        card(p->h->xisf, p->property, p->text.s, "XISF Property");
        p->property_depth = 0;
    }
    if (p->data_depth == p->depth)
        p->data_depth = 0;
    if (p->image_depth == p->depth) {
        fqi_xisf_image *x = p->h->xisf;
        if (x->cards.oom) fail(p, "out of memory");
        else if (!x->have_data && !x->error[0]) fail(p, "missing image Data element");
        else if (x->declared && x->raw && x->declared != x->raw)
            fail(p, "uncompressed block size does not match image geometry");
        else if (x->have_data && !x->embedded && !x->compression[0] && x->raw && x->stored != x->raw)
            fail(p, "attachment size does not match image geometry");
        p->h = NULL;
        p->image_depth = 0;
    }
    p->depth--;
}

static void XMLCALL doctype(void *ctx, const XML_Char *name, const XML_Char *sys,
                            const XML_Char *pub, int internal)
{
    (void)name; (void)sys; (void)pub; (void)internal;
    fail(ctx, "DTDs are not allowed");
}

int fqi_xisf_open(fq_file *f, char *err, size_t errlen)
{
    f->xisf = 1;
    f->scan_done = 1;
    if (f->size < 16) { fqi_seterr(err, errlen, "XISF: truncated signature"); return -1; }
    uint32_t len;
    memcpy(&len, f->data + 8, 4);
    if (!len || len > X_HEADER_LIMIT || (int64_t)len > f->size - 16) {
        fqi_seterr(err, errlen, "XISF: invalid or oversized XML header"); return -1;
    }
    /* XISF headers are UTF-8, including writers that declare the alias utf8. */
    XML_Parser xml = XML_ParserCreateNS("UTF-8", '|');
    if (!xml) { fqi_seterr(err, errlen, "XISF: out of memory"); return -1; }
    xparser p = { .f = f, .parser = xml, .err = err, .errlen = errlen, .header_end = 16u + len };
    XML_SetUserData(xml, &p);
    XML_SetElementHandler(xml, start, end);
    XML_SetCharacterDataHandler(xml, chars);
    XML_SetStartDoctypeDeclHandler(xml, doctype);
    XML_SetParamEntityParsing(xml, XML_PARAM_ENTITY_PARSING_NEVER);
    if (XML_Parse(xml, (const char *)f->data + 16, (int)len, XML_TRUE) == XML_STATUS_ERROR && !p.failed) {
        fqi_seterr(err, errlen, "XISF XML: %s", XML_ErrorString(XML_GetErrorCode(xml)));
        p.failed = 1;
    }
    free(p.text.s);
    XML_ParserFree(xml);
    if (!p.failed && (!p.root || !f->nhdu)) {
        fqi_seterr(err, errlen, "XISF: no images in header");
        return -1;
    }
    return p.failed ? -1 : 0;
}

void fqi_xisf_free(fqi_xisf_image *x)
{
    if (!x) return;
    free(x->blocks);
    free(x->cards.s);
    free(x->encoded.s);
    free(x->decoded);
    free(x);
}

int fqi_xisf_describe(const hdu_t *h, imgdesc *d)
{
    const fqi_xisf_image *x = h->xisf;
    d->bitpix = h->bitpix;
    d->naxis = h->naxis;
    memcpy(d->naxes, h->naxes, sizeof d->naxes);
    d->compressed = x->compression[0] != 0;
    d->supported = !x->error[0];
    fqi_scopy(d->cmptype, sizeof d->cmptype, x->compression);
    return 1;
}

const char *fqi_xisf_type(const hdu_t *h) { return h->xisf->type; }
const char *fqi_xisf_error(const hdu_t *h) { return h->xisf->error; }

int fqi_xisf_keyword(const hdu_t *h, const char *key, char *out, size_t n)
{
    if (!n) return 0;
    const fqi_xisf_image *x = h->xisf;
    if (!strcmp(key, "ROWORDER")) { fqi_scopy(out, n, "TOP-DOWN"); return 1; }
    if (!strcmp(key, "CTYPE3")) { fqi_scopy(out, n, x->channels == 3 ? "RGB" : ""); return 1; }
    if (!strcmp(key, "XBAYROFF") || !strcmp(key, "YBAYROFF")) {
        fqi_scopy(out, n, "0"); return 1;
    }
    if ((!strcmp(key, "BAYERPAT") || !strcmp(key, "COLORTYP")) && x->bayer[0]) {
        fqi_scopy(out, n, x->bayer); return 1;
    }
    if ((!strcmp(key, "BAYERPAT") || !strcmp(key, "COLORTYP")) && x->have_cfa)
        return 0;
    const char *s = x->cards.s;
    size_t k = strlen(key);
    while (s && *s) {
        const char *e = strchr(s, '\n');
        if (!e) break;
        const char *a = s + 2, *b = strchr(a, '\t');
        if (b && (size_t)(b - a) == k && !memcmp(a, key, k)) {
            a = b + 1;
            b = strchr(a, '\t');
            if (!b || b > e) return 0;
            while (a < b && *a == ' ') a++;
            while (b > a && b[-1] == ' ') b--;
            if (b - a >= 2 && *a == '\'' && b[-1] == '\'') { a++; b--; }
            size_t len = (size_t)(b - a);
            if (len >= n) len = n - 1;
            memcpy(out, a, len);
            out[len] = 0;
            return 1;
        }
        s = e + 1;
    }
    return 0;
}

char *fqi_xisf_cards(const hdu_t *h, size_t *len)
{
    const fqi_sbuf *b = &h->xisf->cards;
    char *s = malloc(b->len + 1);
    if (!s) return NULL;
    memcpy(s, b->s ? b->s : "", b->len);
    s[b->len] = 0;
    if (len) *len = b->len;
    return s;
}

/* Decode LZ4 block format, including overlapping matches, with exact bounds. */
static int lz4(const uint8_t *in, size_t n, uint8_t *out, size_t cap)
{
    size_t i = 0, o = 0;
    while (i < n) {
        unsigned token = in[i++];
        size_t len = token >> 4;
        if (len == 15) {
            unsigned v;
            do { if (i == n) return -1; v = in[i++]; if (len > SIZE_MAX - v) return -1; len += v; } while (v == 255);
        }
        if (len > n - i || len > cap - o) return -1;
        memcpy(out + o, in + i, len); i += len; o += len;
        if (i == n) return o == cap ? 0 : -1;
        if (n - i < 2) return -1;
        size_t off = in[i] | ((size_t)in[i + 1] << 8); i += 2;
        if (!off || off > o) return -1;
        len = (token & 15) + 4;
        if ((token & 15) == 15) {
            unsigned v;
            do { if (i == n) return -1; v = in[i++]; if (len > SIZE_MAX - v) return -1; len += v; } while (v == 255);
        }
        if (len > cap - o) return -1;
        for (size_t j = 0; j < len; j++) out[o + j] = out[o + j - off];
        o += len;
    }
    return o == cap ? 0 : -1;
}

static int digit64(unsigned c)
{
    if (c >= 'A' && c <= 'Z') return (int)c - 'A';
    if (c >= 'a' && c <= 'z') return (int)c - 'a' + 26;
    if (c >= '0' && c <= '9') return (int)c - '0' + 52;
    return c == '+' ? 62 : c == '/' ? 63 : -1;
}

static uint8_t *embedded(fqi_xisf_image *x, size_t *len)
{
    uint8_t *out = malloc(x->encoded.len / (x->encoding == 2 ? 2 : 4) * 3 + 3);
    if (!out) return NULL;
    size_t o = 0;
    unsigned acc = 0;
    int bits = 0, padding = 0, count = 0;
    for (size_t i = 0; i < x->encoded.len; i++) {
        unsigned c = (unsigned char)x->encoded.s[i];
        if (isspace(c)) continue;
        if (x->encoding == 2) {
            int d = c >= '0' && c <= '9' ? (int)c - '0' :
                    c >= 'a' && c <= 'f' ? (int)c - 'a' + 10 :
                    c >= 'A' && c <= 'F' ? (int)c - 'A' + 10 : -1;
            if (d < 0) goto bad;
            acc = (acc << 4) | (unsigned)d;
            if (++count == 2) { out[o++] = (uint8_t)acc; count = 0; }
        } else {
            if (c == '=') { padding++; if (padding > 2) goto bad; continue; }
            int d = digit64(c);
            if (padding || d < 0) goto bad;
            acc = (acc << 6) | (unsigned)d;
            bits += 6; count++;
            if (bits >= 8) { bits -= 8; out[o++] = (uint8_t)(acc >> bits); }
        }
    }
    if (x->encoding == 2 ? count != 0 :
        ((count + padding) % 4 || (padding == 1 ? bits != 2 : padding == 2 ? bits != 4 : bits != 0) ||
         (bits && (acc & ((1u << bits) - 1))))) goto bad;
    *len = o;
    return out;
 bad:
    free(out);
    return NULL;
}

static int decompress(const fqi_xisf_image *x, const uint8_t *in, size_t n, uint8_t *out, size_t cap)
{
    if (n == cap) { memcpy(out, in, n); return 0; }
    if (x->codec == X_LZ4) return lz4(in, n, out, cap);
    if (x->codec == X_ZSTD) {
        size_t got = ZSTD_decompress(out, cap, in, n);
        return !ZSTD_isError(got) && got == cap ? 0 : -1;
    }
    if (x->codec == X_ZLIB) {
        z_stream z = { 0 };
        if (n > UINT_MAX || cap > UINT_MAX || inflateInit(&z) != Z_OK) return -1;
        z.next_in = (Bytef *)in; z.avail_in = (uInt)n;
        z.next_out = out; z.avail_out = (uInt)cap;
        int rc = inflate(&z, Z_FINISH);
        int ok = rc == Z_STREAM_END && z.total_out == cap && z.total_in == n;
        inflateEnd(&z);
        return ok ? 0 : -1;
    }
    return -1;
}

int fqi_xisf_load(fq_file *f, hdu_t *h, const uint8_t **data,
                  int *big_endian, int *stride, char *err, size_t errlen)
{
    fqi_xisf_image *x = h->xisf;
    *big_endian = x->big;
    *stride = x->normal ? x->channels : 1;
    if (x->error[0]) { fqi_seterr(err, errlen, "%s", x->error); return -1; }
    if (!x->embedded && !x->compression[0]) { *data = f->data + x->offset; return 0; }
    if (x->decoded) { *data = x->decoded; return 0; }
    if (!x->raw || x->raw > X_DECODE_LIMIT || x->stored > X_DECODE_LIMIT + X_HEADER_LIMIT) {
        fqi_seterr(err, errlen, "XISF image exceeds the 512 MiB decompression limit"); return -1;
    }
    /* Keep at most one decoded image, even when browsing a multi-image file. */
    for (int i = 0; i < f->nhdu; i++) {
        free(f->hdu[i].xisf->decoded);
        f->hdu[i].xisf->decoded = NULL;
    }
    uint8_t *encoded = NULL, *buf = NULL;
    size_t n = x->stored;
    const uint8_t *in = f->data + x->offset;
    if (x->embedded) {
        encoded = embedded(x, &n);
        if (!encoded) goto bad;
        in = encoded;
    }
    if (!x->compression[0]) {
        if (n != x->raw) goto bad;
        x->decoded = encoded;
        *data = x->decoded;
        return 0;
    }
    buf = malloc(x->raw);
    if (!buf) goto bad;
    if (x->nblocks) {
        size_t ci = 0, ui = 0;
        for (size_t i = 0; i < x->nblocks; i++) {
            xblock b = x->blocks[i];
            if (b.stored > n - ci || b.raw > x->raw - ui ||
                decompress(x, in + ci, b.stored, buf + ui, b.raw)) goto bad;
            ci += b.stored; ui += b.raw;
        }
        if (ci != n || ui != x->raw) goto bad;
    } else if (decompress(x, in, n, buf, x->raw)) goto bad;
    free(encoded); encoded = NULL;
    if (x->shuffle > 1) {
        uint8_t *unshuffled = malloc(x->raw);
        if (!unshuffled) goto bad;
        size_t items = x->raw / (size_t)x->shuffle;
        fq_unshuffle(buf, unshuffled, (int64_t)items, x->shuffle);
        size_t tail = items * (size_t)x->shuffle;
        memcpy(unshuffled + tail, buf + tail, x->raw - tail);
        free(buf);
        buf = unshuffled;
    }
    x->decoded = buf;
    *data = buf;
    return 0;
 bad:
    free(encoded);
    free(buf);
    fqi_seterr(err, errlen, "XISF: invalid, truncated, or oversized image data block");
    return -1;
}
