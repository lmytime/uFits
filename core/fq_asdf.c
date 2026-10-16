/* Native, read-only ASDF support: the arrays of a file's tree as images,
   cubes and plots (Roman's files, say), and the tree itself laid out like
   a header. The YAML tree is read with libyaml's event parser, within
   bounds on its size and depth; of the blocks holding the arrays only the
   part with the plane shown is read or decompressed (LZ4 as ASDF frames
   it, zlib or bzip2). Written from the ASDF Standard and what Python's
   asdf writes. */
#include "fq_internal.h"

#include <bzlib.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <yaml.h>

#define A_TREE_LIMIT ((int64_t)64 << 20)    /* bytes of YAML read */
#define A_DECODE_LIMIT ((int64_t)512 << 20) /* bytes decompressed for one plane */
#define A_CHUNK_LIMIT ((int64_t)256 << 20)  /* an LZ4 frame of a block */
#define A_ARRAYS_LIMIT 4096
#define A_BLOCKS_LIMIT 65536
#define A_DEPTH_LIMIT 100
#define A_LINES_LIMIT 50000
#define A_VALUE_LIMIT 400   /* characters of a value shown */
#define A_KEY_LIMIT 120
#define A_PATH_LIMIT 512

enum { K_NONE, K_INT, K_UINT, K_FLOAT, K_BOOL, K_OTHER };
#define NO_SOURCE INT64_MIN

typedef struct {
    int64_t data_off, used, size;   /* stored bytes from data_off, and decoded */
    char comp[8];                   /* "", "lz4", "zlib", "bzp2" or another label */
    int truncated;                  /* the file ends before the stored bytes do */
} ablock;

struct fqi_asdf_array {
    char path[A_PATH_LIMIT];        /* where in the tree: "roman.data" */
    char dtype[24];                 /* datatype as written: "float32" */
    char error[160];                /* why it cannot be shown */
    int kind, size, big;            /* K_*, bytes per element, big-endian */
    int nshape, nstrides, star;     /* star: shape begins with '*' (streamed) */
    int64_t shape[FQ_MAXAXES], strides[FQ_MAXAXES];
    int64_t offset, source;         /* source: block index (from the end if
                                       negative), NO_SOURCE if none */
    int inline_data, external, masked, mask, filtered, listed, bad_field;
};

struct fqi_asdf {
    fqi_asdf_array *arrays, tree_only;
    int narrays, cap;
    ablock *blocks;
    int nblocks;
    fqi_sbuf cards;
    uint8_t *decoded;               /* one plane, decompressed or gathered */
    const fqi_asdf_array *decoded_array;
    int64_t decoded_plane;
};

/* ------------------------------------------------------------- the tree */

enum { FR_NODE, FR_ARRAY, FR_FIELD, FR_IGNORE, FR_COLLECT };
enum { FIELD_SHAPE = 1, FIELD_STRIDES, FIELD_DTYPE };

typedef struct {
    int type, is_map, want_key;
    int nd, field;                  /* FR_ARRAY, FR_FIELD: the array */
    int filtered, quantity, root;   /* arrays below are not listed; unit/quantity */
    int croot;                      /* the flow sequence collected on one line */
    int tail;                       /* asdf_library, history: shown last */
    int indent;                     /* of this node's line; children +2 */
    int64_t items;
    size_t path_len;                /* the path before this node */
    char key[A_KEY_LIMIT + 1];      /* mappings: the current key */
    char label[A_KEY_LIMIT + 24];   /* FR_ARRAY, collected sequences: the line */
    char tag[64];
} aframe;

typedef struct {
    fqi_asdf *a;
    aframe st[A_DEPTH_LIMIT];
    int depth, stop, lines, collecting;
    int tail;                       /* lines go to the end of the header */
    fqi_sbuf tail_lines;
    char path[A_PATH_LIMIT];
    size_t path_len;
    fqi_sbuf collect;               /* a flow sequence, as written */
    int64_t item_at[1000];          /* where its items start in collect */
    int nitems;
    char problem[200];
} actx;

/* Printable ASCII: a '?' for each other character, spaces for tabs and
   line breaks, and "..." when cut at limit characters. */
static void put_text(fqi_sbuf *b, const char *s, size_t n, size_t limit)
{
    size_t shown = 0, i = 0;
    for (; i < n && shown < limit; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (ch >= 0x80 && ch < 0xc0)
            continue;   /* the rest of a UTF-8 character */
        char out = ch == '\t' || ch == '\n' || ch == '\r' ? ' ' : ch < 32 || ch >= 127 ? '?' : (char)ch;
        fqi_sb_add(b, &out, 1);
        shown++;
    }
    for (; i < n; i++)
        if (((unsigned char)s[i] & 0xc0) != 0x80) {
            fqi_sb_add(b, "...", 3);
            break;
        }
}

static void line(actx *c, char kind, int indent, const char *key, const char *val, size_t vlen,
                 const char *comment)
{
    fqi_sbuf *b = c->tail ? &c->tail_lines : &c->a->cards;
    if (c->lines >= A_LINES_LIMIT) {
        if (c->lines++ == A_LINES_LIMIT)
            fqi_sb_printf(b, "c\t#\t\tthe tree goes on beyond %d lines\n", A_LINES_LIMIT);
        return;
    }
    c->lines++;
    fqi_sb_add(b, &kind, 1);
    fqi_sb_add(b, "\t", 1);
    for (int i = 0; i < indent && i < 2 * A_DEPTH_LIMIT; i++)
        fqi_sb_add(b, " ", 1);
    put_text(b, key, strlen(key), A_KEY_LIMIT);
    fqi_sb_add(b, "\t", 1);
    if (val)
        put_text(b, val, vlen, A_VALUE_LIMIT);
    fqi_sb_add(b, "\t", 1);
    if (comment)
        put_text(b, comment, strlen(comment), 80);
    fqi_sb_add(b, "\n", 1);
}

/* A tag as shown: its last part ("time-1.4.0", "wfi_image-2.2.0"); none
   for YAML's own types. */
static void tag_name(const yaml_char_t *tag, char *out, size_t n)
{
    out[0] = 0;
    if (!tag)
        return;
    const char *t = (const char *)tag;
    if (!strncmp(t, "tag:yaml.org,2002:", 18) || !strcmp(t, "!"))
        return;
    const char *s = strrchr(t, '/');
    if (!s || !s[1])
        s = strrchr(t, ':');
    s = s && s[1] ? s + 1 : t;
    fqi_sbuf b = { 0 };
    put_text(&b, s, strlen(s), n > 4 ? n - 4 : 1);
    fqi_scopy(out, n, b.s ? b.s : "");
    free(b.s);
}

static int has_tag(const yaml_char_t *tag, const char *part)
{
    return tag && strstr((const char *)tag, part) != NULL;
}

static int parse_i64(const char *s, size_t n, int64_t *v)
{
    if (!n || n > 24)
        return 0;
    char b[32];
    memcpy(b, s, n);
    b[n] = 0;
    char *end;
    long long x = strtoll(b, &end, 10);
    if (end == b || *end)
        return 0;
    *v = (int64_t)x;
    return 1;
}

static void set_dtype(fqi_asdf_array *nd, const char *s)
{
    static const struct { const char *name; int kind, size; } types[] = {
        { "int8", K_INT, 1 },     { "uint8", K_UINT, 1 },   { "int16", K_INT, 2 },
        { "uint16", K_UINT, 2 },  { "int32", K_INT, 4 },    { "uint32", K_UINT, 4 },
        { "int64", K_INT, 8 },    { "uint64", K_UINT, 8 },  { "float16", K_FLOAT, 2 },
        { "float32", K_FLOAT, 4 }, { "float64", K_FLOAT, 8 }, { "bool8", K_BOOL, 1 },
    };
    fqi_scopy(nd->dtype, sizeof nd->dtype, s);
    nd->kind = K_OTHER;
    for (size_t i = 0; i < sizeof types / sizeof *types; i++)
        if (!strcmp(s, types[i].name)) {
            nd->kind = types[i].kind;
            nd->size = types[i].size;
        }
}

/* A scalar field of an ndarray. */
static void array_scalar(fqi_asdf_array *nd, const char *key, const char *s, size_t n)
{
    int64_t v;
    if (!strcmp(key, "source")) {
        if (parse_i64(s, n, &v) && v > NO_SOURCE)
            nd->source = v;
        else
            nd->external = 1;
    } else if (!strcmp(key, "datatype")) {
        char b[24];
        fqi_scopy(b, sizeof b, n < sizeof b ? s : "?");
        set_dtype(nd, b);
    } else if (!strcmp(key, "byteorder")) {
        nd->big = n == 3 && !memcmp(s, "big", 3);
    } else if (!strcmp(key, "offset")) {
        if (!parse_i64(s, n, &nd->offset) || nd->offset < 0)
            nd->bad_field = 1;
    } else if (!strcmp(key, "mask")) {
        nd->masked = 1;
    }
}

static fqi_asdf_array *new_array(actx *c)
{
    fqi_asdf *a = c->a;
    if (a->narrays >= A_ARRAYS_LIMIT)
        return NULL;
    if (a->narrays == a->cap) {
        int cap = a->cap ? a->cap * 2 : 16;
        fqi_asdf_array *p = realloc(a->arrays, (size_t)cap * sizeof *p);
        if (!p)
            return NULL;
        a->arrays = p;
        a->cap = cap;
    }
    fqi_asdf_array *nd = &a->arrays[a->narrays++];
    memset(nd, 0, sizeof *nd);
    nd->source = NO_SOURCE;
    return nd;
}

static aframe *push(actx *c, int type, int is_map)
{
    if (c->depth >= A_DEPTH_LIMIT) {
        snprintf(c->problem, sizeof c->problem, "the tree is nested deeper than %d levels", A_DEPTH_LIMIT);
        c->stop = 1;
        return NULL;
    }
    aframe *fr = &c->st[c->depth++];
    memset(fr, 0, sizeof *fr);
    fr->type = type;
    fr->is_map = is_map;
    fr->want_key = is_map;
    fr->nd = -1;
    fr->path_len = c->path_len;
    return fr;
}

static void add_path(actx *c, const char *label, int is_item)
{
    char seg[A_KEY_LIMIT + 24];
    snprintf(seg, sizeof seg, "%s%s", c->path_len && !is_item ? "." : "", label);
    size_t n = strlen(seg);
    if (c->path_len + n < sizeof c->path) {
        memcpy(c->path + c->path_len, seg, n + 1);
        c->path_len += n;
    }
}

/* After a key or a value of a mapping: a value or a key comes next. */
static void done_node(aframe *p)
{
    if (p && p->is_map)
        p->want_key = !p->want_key;
}

#define A_COLLECT_LIMIT (64 << 10)

static void collect(actx *c, const char *s, size_t n)
{
    if (c->collect.len < A_COLLECT_LIMIT)
        fqi_sb_add(&c->collect, s, n < A_COLLECT_LIMIT ? n : A_COLLECT_LIMIT);
}

/* "(4088, 4088) float32" and "ndarray, block 0, lz4" for an array's line. */
static void array_line(actx *c, const aframe *fr, const fqi_asdf_array *nd)
{
    char val[256], com[160];
    int o = snprintf(val, sizeof val, "(");
    for (int i = 0; i < nd->nshape && o < (int)sizeof val - 40; i++)
        o += snprintf(val + o, sizeof val - (size_t)o, i ? ", %lld" : "%lld", (long long)nd->shape[i]);
    snprintf(val + o, sizeof val - (size_t)o, "%s) %s", nd->nshape == 1 ? "," : "", nd->dtype[0] ? nd->dtype : "?");
    if (nd->star)
        val[1] = '*';
    if (nd->inline_data)
        snprintf(com, sizeof com, "%s, inline", fr->tag);
    else if (nd->external)
        snprintf(com, sizeof com, "%s, in another file", fr->tag);
    else if (nd->source == NO_SOURCE)
        snprintf(com, sizeof com, "%s, no block", fr->tag);
    else if (nd->source >= 0 && nd->source < c->a->nblocks && c->a->blocks[nd->source].comp[0])
        snprintf(com, sizeof com, "%s, block %lld, %s", fr->tag, (long long)nd->source,
                 c->a->blocks[nd->source].comp);
    else
        snprintf(com, sizeof com, "%s, block %lld", fr->tag, (long long)nd->source);
    if (nd->masked)
        fqi_scopy(com + strlen(com), sizeof com - strlen(com), ", masked");
    line(c, 'v', fr->indent, fr->label, val, strlen(val), com);
}

static void node(actx *c, const yaml_event_t *e)
{
    int scalar = e->type == YAML_SCALAR_EVENT, alias = e->type == YAML_ALIAS_EVENT;
    int map = e->type == YAML_MAPPING_START_EVENT, coll = !scalar && !alias;
    const yaml_char_t *tag = scalar ? e->data.scalar.tag
                             : map  ? e->data.mapping_start.tag
                             : coll ? e->data.sequence_start.tag : NULL;
    const char *text = scalar ? (const char *)e->data.scalar.value
                       : alias ? (const char *)e->data.alias.anchor : "";
    size_t tlen = scalar ? e->data.scalar.length : strlen(text);
    aframe *p = c->depth ? &c->st[c->depth - 1] : NULL;

    if (p && p->type == FR_IGNORE) {
        if (coll)
            push(c, FR_IGNORE, map);
        return;
    }
    /* Within a flow sequence shown on one line, as written. */
    if (c->collecting) {
        if (p->is_map && !p->want_key)
            collect(c, ": ", 2);
        else if (p->items++)
            collect(c, ", ", 2);
        if (p->croot && c->nitems < (int)(sizeof c->item_at / sizeof *c->item_at))
            c->item_at[c->nitems++] = (int64_t)c->collect.len;
        if (coll) {
            collect(c, map ? "{" : "[", 1);
            push(c, FR_COLLECT, map);
        } else {
            if (alias)
                collect(c, "*", 1);
            collect(c, text, tlen);
            done_node(p);
        }
        return;
    }
    /* A key: shown with its value. Keys that are collections are not. */
    if (p && p->is_map && p->want_key) {
        if (coll) {
            fqi_scopy(p->key, sizeof p->key, "?");
            push(c, FR_IGNORE, map);
            return;
        }
        fqi_sbuf k = { 0 };
        if (alias)
            fqi_sb_add(&k, "*", 1);
        put_text(&k, text, tlen, A_KEY_LIMIT - 1);
        fqi_scopy(p->key, sizeof p->key, k.s ? k.s : "");
        free(k.s);
        done_node(p);
        return;
    }
    char label[A_KEY_LIMIT + 24] = "";
    if (p && p->is_map)
        fqi_scopy(label, sizeof label, p->key);
    else if (p)
        snprintf(label, sizeof label, "[%lld]", (long long)p->items++);

    /* The fields of an ndarray. */
    if (p && p->type == FR_ARRAY) {
        fqi_asdf_array *nd = &c->a->arrays[p->nd];
        if (scalar) {
            array_scalar(nd, p->key, text, tlen);
            done_node(p);
        } else if (alias) {
            done_node(p);
        } else if (map && has_tag(tag, "/ndarray-") && !strcmp(p->key, "mask")) {
            int parent = p->nd;
            fqi_asdf_array *m = new_array(c);
            aframe *fr = m ? push(c, FR_ARRAY, 1) : push(c, FR_IGNORE, 1);
            if (m && fr) {
                c->a->arrays[parent].masked = 1;
                m->mask = 1;
                fr->nd = (int)(m - c->a->arrays);
            }
        } else {
            int field = !strcmp(p->key, "shape") ? FIELD_SHAPE : !strcmp(p->key, "strides") ? FIELD_STRIDES
                        : !strcmp(p->key, "datatype") ? FIELD_DTYPE : 0;
            if (!strcmp(p->key, "data"))
                nd->inline_data = 1;
            if (!strcmp(p->key, "mask"))
                nd->masked = 1;
            if (field == FIELD_DTYPE)
                set_dtype(nd, map ? "record" : "string");
            if (field == FIELD_SHAPE)
                nd->nshape = 0;
            if (field == FIELD_STRIDES)
                nd->nstrides = 0;
            aframe *fr = push(c, field && !map ? FR_FIELD : FR_IGNORE, map);
            if (fr) {
                fr->nd = p->nd;
                fr->field = field;
            }
        }
        return;
    }
    if (p && p->type == FR_FIELD) {
        fqi_asdf_array *nd = &c->a->arrays[p->nd];
        int64_t v = 0;
        if (coll) {
            if (p->field == FIELD_DTYPE && p->items == 1)
                set_dtype(nd, "record");
            else if (p->field != FIELD_DTYPE)
                nd->bad_field = 1;
            push(c, FR_IGNORE, map);
        } else if (p->field == FIELD_SHAPE) {
            if (p->items == 1 && tlen == 1 && text[0] == '*')
                nd->star = 1;
            else if (!parse_i64(text, tlen, &v) || v < 0)
                nd->bad_field = 1;
            if (nd->nshape < FQ_MAXAXES)
                nd->shape[nd->nshape] = v;
            nd->nshape++;
        } else if (p->field == FIELD_STRIDES) {
            if (!parse_i64(text, tlen, &v) || v == 0)
                nd->bad_field = 1;
            if (nd->nstrides < FQ_MAXAXES)
                nd->strides[nd->nstrides] = v;
            nd->nstrides++;
        }
        return;
    }

    /* A node of the tree: a line of the header (the root has none). What
       wrote the file (asdf_library, history) comes last. */
    int indent = p ? p->indent + (p->root ? 0 : 2) : 0;
    int tail = p && p->root && (!strcmp(label, "asdf_library") || !strcmp(label, "history"));
    char tname[64];
    tag_name(tag, tname, sizeof tname);
    if (tail)
        c->tail = 1;
    if (scalar || alias) {
        if (alias) {
            char v[A_KEY_LIMIT + 2];
            snprintf(v, sizeof v, "*%s", text);
            line(c, 'v', indent, label, v, strlen(v), NULL);
        } else {
            line(c, 'v', indent, label, text, tlen, tname[0] ? tname : NULL);
        }
        if (tail)
            c->tail = 0;
        done_node(p);
        return;
    }
    int filtered = (p && p->filtered) || has_tag(tag, "transform") || has_tag(tag, "gwcs") ||
                   has_tag(tag, "table");
    if (map && has_tag(tag, "/ndarray-")) {
        fqi_asdf_array *nd = new_array(c);
        aframe *fr = push(c, nd ? FR_ARRAY : FR_IGNORE, 1);
        if (!fr) {
            c->tail = 0;
            return;
        }
        fr->tail = tail;
        if (p)
            add_path(c, label, !p->is_map);
        if (nd) {
            fr->nd = (int)(nd - c->a->arrays);
            nd->filtered = filtered;
            fqi_scopy(nd->path, sizeof nd->path, c->path);
            /* The value of a quantity is named for the quantity. */
            if (p && p->quantity && !strcmp(label, "value"))
                nd->path[fr->path_len] = 0;
        }
        fr->indent = indent;
        fqi_scopy(fr->label, sizeof fr->label, label);
        fqi_scopy(fr->tag, sizeof fr->tag, tname[0] ? tname : "ndarray");
        return;
    }
    if (!map && e->data.sequence_start.style == YAML_FLOW_SEQUENCE_STYLE && p) {
        aframe *fr = push(c, FR_COLLECT, 0);
        if (!fr) {
            c->tail = 0;
            return;
        }
        fr->indent = indent;
        fr->croot = 1;
        fr->tail = tail;
        fqi_scopy(fr->label, sizeof fr->label, label);
        fqi_scopy(fr->tag, sizeof fr->tag, tname);
        c->collecting = 1;
        c->collect.len = 0;
        c->nitems = 0;
        collect(c, "[", 1);
        return;
    }
    if (p)
        line(c, 'c', indent, label, NULL, 0, tname[0] ? tname : NULL);
    aframe *fr = push(c, FR_NODE, map);
    if (!fr) {
        c->tail = 0;
        return;
    }
    if (p)
        add_path(c, label, !p->is_map);
    fr->root = !p;
    fr->tail = tail;
    fr->indent = indent;
    fr->filtered = filtered;
    fr->quantity = map && has_tag(tag, "/quantity-");
}

static void pop(actx *c)
{
    if (!c->depth)
        return;
    aframe *fr = &c->st[--c->depth];
    aframe *p = c->depth ? &c->st[c->depth - 1] : NULL;
    if (fr->type == FR_COLLECT) {
        collect(c, fr->is_map ? "}" : "]", 1);
        if (fr->croot)
            c->collecting = 0;
        if (fr->croot && c->collect.s && !c->collect.oom) {
            const char *t = c->collect.s;
            size_t len = c->collect.len;
            if (len <= A_VALUE_LIMIT) {
                line(c, 'v', fr->indent, fr->label, t, len, fr->tag[0] ? fr->tag : NULL);
            } else {   /* a long one: a line per item */
                line(c, 'c', fr->indent, fr->label, NULL, 0, fr->tag[0] ? fr->tag : NULL);
                for (int i = 0; i < c->nitems; i++) {
                    int64_t a = c->item_at[i], b = i + 1 < c->nitems ? c->item_at[i + 1] - 2 : (int64_t)len - 1;
                    char key[24];
                    snprintf(key, sizeof key, "[%d]", i);
                    if (b > a)
                        line(c, 'v', fr->indent + 2, key, t + a, (size_t)(b - a), NULL);
                }
                if ((int64_t)fr->items > c->nitems || len >= A_COLLECT_LIMIT)
                    line(c, 'c', fr->indent + 2, "...", NULL, 0, NULL);
            }
        }
    } else if (fr->type == FR_ARRAY) {
        fqi_asdf_array *nd = &c->a->arrays[fr->nd];
        if (nd->source < 0 && nd->source != NO_SOURCE)   /* -1: the last block */
            nd->source = nd->source + c->a->nblocks >= 0 ? nd->source + c->a->nblocks : NO_SOURCE;
        if (!nd->mask)
            array_line(c, fr, nd);
    }
    if (fr->tail)
        c->tail = 0;
    c->path_len = fr->path_len;
    c->path[c->path_len] = 0;
    done_node(p);
}

/* -------------------------------------------------------- the blocks */

static const uint8_t magic[4] = { 0xd3, 'B', 'L', 'K' };

static int64_t find_magic(const uint8_t *d, int64_t from, int64_t n)
{
    for (int64_t i = from; i + 4 <= n;) {
        const uint8_t *p = memchr(d + i, 0xd3, (size_t)(n - i));
        if (!p)
            return -1;
        i = p - d;
        if (i + 4 <= n && !memcmp(p, magic, 4))
            return i;
        i++;
    }
    return -1;
}

/* Where the tree ends: after a line "..." (Python asdf's rule). */
static int64_t find_tree_end(const uint8_t *d, int64_t n)
{
    for (int64_t i = 0; i < n;) {
        const uint8_t *p = memchr(d + i, '\n', (size_t)(n - i));
        if (!p)
            return -1;
        i = p - d + 1;
        if (n - i >= 3 && !memcmp(d + i, "...", 3)) {
            int64_t k = i + 3;
            if (k == n)
                return k;
            if (d[k] == '\n')
                return k + 1;
            if (d[k] == '\r' && k + 1 < n && d[k + 1] == '\n')
                return k + 2;
        }
    }
    return -1;
}

static void scan_blocks(fqi_asdf *a, const uint8_t *d, int64_t n, int64_t pos)
{
    for (; pos >= 0 && pos + 6 <= n && !memcmp(d + pos, magic, 4) && a->nblocks < A_BLOCKS_LIMIT;) {
        uint16_t hs = fq_be16(d + pos + 4);
        if (hs < 48 || pos + 6 + hs > n)
            break;
        const uint8_t *h = d + pos + 6;
        uint32_t flags = fq_be32(h);
        uint64_t alloc = fq_be64(h + 8), used = fq_be64(h + 16), size = fq_be64(h + 24);
        ablock b = { 0 };
        b.data_off = pos + 6 + hs;
        for (int i = 0; i < 4 && h[4 + i]; i++)
            b.comp[i] = (char)(h[4 + i] >= 32 && h[4 + i] < 127 ? h[4 + i] : '?');
        if (flags & 1) {   /* streamed: the data runs to the end of the file */
            b.used = b.size = n - b.data_off;
            alloc = (uint64_t)b.used;
            b.comp[0] = 0;
        } else {
            if (alloc > (uint64_t)BIG || used > alloc || size > (uint64_t)BIG)
                break;
            b.used = (int64_t)used;
            b.size = b.comp[0] ? (int64_t)size : (int64_t)used;
            b.truncated = b.data_off + b.used > n;
        }
        if (a->nblocks % 64 == 0) {
            ablock *p = realloc(a->blocks, (size_t)(a->nblocks + 64) * sizeof *p);
            if (!p)
                break;
            a->blocks = p;
        }
        a->blocks[a->nblocks++] = b;
        if (flags & 1)
            break;
        pos = fqi_add_sat(b.data_off, (int64_t)alloc);
    }
}

/* ----------------------------------------------------------- the arrays */

static int64_t nelem(const fqi_asdf_array *nd)
{
    int64_t n = 1;
    for (int i = 0; i < nd->nshape && i < FQ_MAXAXES; i++)
        n = fqi_mul_sat(n, nd->shape[i]);
    return n;
}

/* The lowest and highest byte (exclusive) of a part of an array: the first
   `first` elements of axis 0 ... in fact any box: lo/hi over every element
   with index i on each axis below count[axis]. */
static void reach(const fqi_asdf_array *nd, const int64_t *count, int64_t base, int64_t *lo, int64_t *hi)
{
    *lo = *hi = base;
    for (int i = 0; i < nd->nshape; i++) {
        int64_t span = fqi_mul_sat(count[i] - 1, nd->strides[i] < 0 ? -nd->strides[i] : nd->strides[i]);
        if (nd->strides[i] < 0)
            *lo = span >= BIG ? -BIG : *lo - span;
        else
            *hi = fqi_add_sat(*hi, span);
    }
    *hi = fqi_add_sat(*hi, nd->size);
}

/* Whether an array can be shown, and its shape and strides completed. */
static void check_array(fqi_asdf *a, fqi_asdf_array *nd)
{
    if (nd->mask || nd->inline_data || nd->filtered || nd->kind == K_NONE)
        return;
    if (nd->kind == K_OTHER || nd->nshape < 1 || nd->bad_field)
        return;
    nd->listed = 1;
    if (nd->nshape > FQ_MAXAXES) {
        snprintf(nd->error, sizeof nd->error, "ASDF arrays of more than %d dimensions are not supported", FQ_MAXAXES);
        nd->nshape = FQ_MAXAXES;
        return;
    }
    if (nd->external) {
        fqi_scopy(nd->error, sizeof nd->error, "the array's data is in another file");
        return;
    }
    if (nd->source < 0) {
        fqi_scopy(nd->error, sizeof nd->error, "the array has no block of data");
        return;
    }
    if (nd->source >= a->nblocks) {
        snprintf(nd->error, sizeof nd->error, "the file ends before block %lld of the array", (long long)nd->source);
        return;
    }
    ablock *b = &a->blocks[nd->source];
    if (b->truncated) {
        snprintf(nd->error, sizeof nd->error, "the file ends before block %lld of the array", (long long)nd->source);
        return;
    }
    if (b->comp[0] && strcmp(b->comp, "lz4") && strcmp(b->comp, "zlib") && strcmp(b->comp, "bzp2")) {
        snprintf(nd->error, sizeof nd->error, "ASDF compression '%s' is not supported", b->comp);
        return;
    }
    int64_t row = nd->size;
    for (int i = 1; i < nd->nshape; i++)
        row = fqi_mul_sat(row, nd->shape[i]);
    if (nd->star)   /* streamed: as many rows as the block holds */
        nd->shape[0] = row > 0 && b->size > nd->offset ? (b->size - nd->offset) / row : 0;
    for (int i = 0; i < nd->nshape; i++)
        if (nd->shape[i] < 1)
            nd->listed = 0;
    if (nelem(nd) < 2 || nelem(nd) >= BIG)
        nd->listed = 0;
    if (!nd->listed)
        return;
    if (nd->nstrides && nd->nstrides != nd->nshape) {
        fqi_scopy(nd->error, sizeof nd->error, "the array's strides do not match its shape");
        return;
    }
    if (!nd->nstrides) {   /* C order */
        int64_t s = nd->size;
        for (int i = nd->nshape - 1; i >= 0; i--) {
            nd->strides[i] = s;
            s = fqi_mul_sat(s, nd->shape[i]);
        }
        nd->nstrides = nd->nshape;
    }
    int64_t lo, hi;
    reach(nd, nd->shape, nd->offset, &lo, &hi);
    if (lo < 0 || hi > b->size || hi >= BIG)
        fqi_scopy(nd->error, sizeof nd->error, "the array runs past the end of its block");
}

static int contiguous(const fqi_asdf_array *nd)
{
    int64_t s = nd->size;
    for (int i = nd->nshape - 1; i >= 0; i--) {
        if (nd->shape[i] > 1 && nd->strides[i] != s)
            return 0;
        s = fqi_mul_sat(s, nd->shape[i]);
    }
    return 1;
}

/* ------------------------------------------------------------- open */

int fqi_asdf_open(fq_file *f, char *err, size_t errlen)
{
    if (f->z)   /* gzipped: the blocks may be anywhere */
        fqi_need(f, BIG);
    const uint8_t *d = f->data;
    int64_t n = f->size;
    fqi_asdf *a = calloc(1, sizeof *a);
    if (!a) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }
    f->asdf = a;
    f->scan_done = 1;

    /* The version lines, then the tree (if any) up to its "...". */
    actx *c = calloc(1, sizeof *c);
    if (!c) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }
    c->a = a;
    for (int64_t i = 0; i < n && i < 4096 && d[i] == '#';) {
        const uint8_t *nl = memchr(d + i, '\n', (size_t)(n - i));
        int64_t e = nl ? nl - d : n;
        if ((e - i >= 6 && !memcmp(d + i, "#ASDF ", 6)) || (e - i >= 15 && !memcmp(d + i, "#ASDF_STANDARD ", 15))) {
            char key[80];
            int k = (int)(e - i < (int64_t)sizeof key ? e - i : (int64_t)sizeof key - 1);
            memcpy(key, d + i, (size_t)k);
            key[k] = 0;
            if (k && key[k - 1] == '\r')
                key[k - 1] = 0;
            c->tail = 1;
            line(c, 'c', 0, key, NULL, 0, NULL);
            c->tail = 0;
        }
        i = e + 1;
    }
    int64_t first_block = find_magic(d, 0, n);
    int64_t yaml_len = first_block >= 0 ? first_block : n;
    if (yaml_len > A_TREE_LIMIT)
        yaml_len = A_TREE_LIMIT;
    int64_t tree_end = find_tree_end(d, yaml_len);
    int has_tree = 0;
    for (int64_t i = 0; i + 5 <= yaml_len && i < 65536; i++)
        if ((i == 0 || d[i - 1] == '\n') && (!memcmp(d + i, "%YAML", 5) || !memcmp(d + i, "---", 3))) {
            has_tree = 1;
            break;
        }
    if (tree_end < 0 && has_tree)
        snprintf(c->problem, sizeof c->problem, yaml_len >= A_TREE_LIMIT ? "the tree is larger than 64 MiB"
                                                                         : "the tree has no end (\"...\")");
    if (tree_end < 0)
        tree_end = has_tree ? yaml_len : 0;
    scan_blocks(a, d, n, find_magic(d, tree_end, n));

    if (has_tree && tree_end > 0) {
        yaml_parser_t parser;
        yaml_event_t ev;
        if (!yaml_parser_initialize(&parser)) {
            free(c);
            fqi_seterr(err, errlen, "out of memory");
            return -1;
        }
        yaml_parser_set_input_string(&parser, d, (size_t)tree_end);
        while (!c->stop) {
            if (!yaml_parser_parse(&parser, &ev)) {
                if (!c->problem[0])
                    snprintf(c->problem, sizeof c->problem, "YAML: %s at line %lu",
                             parser.problem ? parser.problem : "error", (unsigned long)parser.problem_mark.line + 1);
                break;
            }
            switch (ev.type) {
            case YAML_MAPPING_START_EVENT:
            case YAML_SEQUENCE_START_EVENT:
            case YAML_SCALAR_EVENT:
            case YAML_ALIAS_EVENT:
                node(c, &ev);
                break;
            case YAML_MAPPING_END_EVENT:
            case YAML_SEQUENCE_END_EVENT:
                pop(c);
                break;
            case YAML_DOCUMENT_END_EVENT:
            case YAML_STREAM_END_EVENT:
                c->stop = 1;   /* ASDF has one document */
                break;
            default:
                break;
            }
            yaml_event_delete(&ev);
        }
        yaml_parser_delete(&parser);
        /* What a cut-off tree held so far still counts. */
        while (c->depth) {
            if (c->st[c->depth - 1].type == FR_ARRAY)
                c->a->arrays[c->st[c->depth - 1].nd].bad_field = 1;
            pop(c);
        }
    }
    if (c->problem[0])
        line(c, 'c', 0, "#", NULL, 0, c->problem);
    if (c->tail_lines.len)
        fqi_sb_add(&a->cards, c->tail_lines.s, c->tail_lines.len);
    if (c->tail_lines.oom)
        a->cards.oom = 1;
    free(c->tail_lines.s);
    free(c->collect.s);
    free(c);
    if (a->cards.oom) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }

    /* One HDU per array shown, in the tree's order. */
    for (int i = 0; i < a->narrays; i++)
        check_array(a, &a->arrays[i]);
    int count = 0;
    for (int i = 0; i < a->narrays; i++)
        count += a->arrays[i].listed;
    f->hdu = calloc((size_t)(count ? count : 1), sizeof *f->hdu);
    if (!f->hdu) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }
    f->hcap = count ? count : 1;
    for (int i = 0; i < a->narrays; i++) {
        fqi_asdf_array *nd = &a->arrays[i];
        if (!nd->listed)
            continue;
        hdu_t *h = &f->hdu[f->nhdu++];
        h->asdf = nd;
        h->bscale = 1;
        h->naxis = nd->nshape;
        for (int k = 0; k < nd->nshape; k++)
            h->naxes[k] = nd->shape[nd->nshape - 1 - k];
        h->bitpix = nd->kind == K_FLOAT ? -8 * nd->size : 8 * nd->size;
        h->data_len = fqi_mul_sat(nelem(nd), nd->size);
        size_t len = strlen(nd->path);
        fqi_scopy(h->extname, sizeof h->extname,
                  len < sizeof h->extname ? nd->path : nd->path + len - (sizeof h->extname - 1));
    }
    if (!f->nhdu) {   /* no array to show: the tree still is */
        hdu_t *h = &f->hdu[f->nhdu++];
        a->tree_only.kind = K_NONE;
        fqi_scopy(a->tree_only.error, sizeof a->tree_only.error, "no array to show in this ASDF file");
        h->asdf = &a->tree_only;
        fqi_scopy(h->extname, sizeof h->extname, "tree");
    }
    return 0;
}

void fqi_asdf_free(fqi_asdf *a)
{
    if (!a)
        return;
    free(a->arrays);
    free(a->blocks);
    free(a->cards.s);
    free(a->decoded);
    free(a);
}

int fqi_asdf_describe(const hdu_t *h, imgdesc *d)
{
    const fqi_asdf_array *nd = h->asdf;
    if (!nd->listed)
        return 0;
    d->bitpix = h->bitpix;
    d->naxis = h->naxis;
    memcpy(d->naxes, h->naxes, sizeof d->naxes);
    d->supported = !nd->error[0];
    return 1;
}

int fqi_asdf_compression(const fq_file *f, const hdu_t *h, char *out, size_t n)
{
    const fqi_asdf_array *nd = h->asdf;
    out[0] = 0;
    if (nd->listed && nd->source >= 0 && nd->source < f->asdf->nblocks)
        fqi_scopy(out, n, f->asdf->blocks[nd->source].comp);
    return out[0] != 0;
}

const char *fqi_asdf_type(const hdu_t *h) { return h->asdf->dtype[0] ? h->asdf->dtype : "?"; }
const char *fqi_asdf_error(const hdu_t *h) { return h->asdf->error; }
int fqi_asdf_signed(const hdu_t *h) { return h->asdf->kind == K_INT; }

int fqi_asdf_keyword(const hdu_t *h, const char *key, char *out, size_t n)
{
    if (!n || strcmp(key, "EXTNAME"))
        return 0;
    fqi_scopy(out, n, h->extname);
    return 1;
}

char *fqi_asdf_cards(const fq_file *f, size_t *len)
{
    const fqi_sbuf *b = &f->asdf->cards;
    char *s = malloc(b->len + 1);
    if (!s)
        return NULL;
    memcpy(s, b->s ? b->s : "", b->len);
    s[b->len] = 0;
    if (len)
        *len = b->len;
    return s;
}

/* The HDU to show first: an image named "data" (Roman's, JWST's), if any. */
int fqi_asdf_preferred(fq_file *f)
{
    for (int i = 0; i < f->nhdu; i++) {
        const fqi_asdf_array *nd = f->hdu[i].asdf;
        size_t len = strlen(nd->path);
        if (nd->listed && !nd->error[0] && nd->nshape >= 2 && len >= 4 && !strcmp(nd->path + len - 4, "data") &&
            (len == 4 || nd->path[len - 5] == '.'))
            return i;
    }
    return -1;
}

/* ------------------------------------------------------------ decoding */

/* LZ4 frames that lie wholly in the range asked for, decoded in parallel. */
typedef struct {
    const uint8_t *src;
    size_t slen;
    uint8_t *dst;
    uint32_t raw;
} lzframe;

typedef struct {
    lzframe *frames;
    int failed;
} lzjob;

static void lz4_task(void *ctx, size_t i)
{
    lzjob *J = ctx;
    const lzframe *fr = &J->frames[i];
    if (fq_lz4_decode(fr->src, fr->slen, fr->dst, fr->raw))
        __atomic_store_n(&J->failed, 1, __ATOMIC_RELAXED);
}

/* Bytes [start, start + len) of a block's data, decompressed into out. */
static int lz4_range(const uint8_t *in, int64_t n, int64_t start, int64_t len, uint8_t *out, int threads)
{
    /* Frames of [4-byte big-endian length][4-byte little-endian size][LZ4
       block], as Python's asdf writes them (lz4.block with its size). */
    int64_t i = 0, pos = 0, end = start + len;
    lzjob J = { NULL, 0 };
    size_t nframes = 0, cap = 0;
    int rc = -1;
    while (pos < end) {
        if (n - i < 8)
            goto done;
        uint32_t clen = fq_be32(in + i);
        uint32_t raw = (uint32_t)in[i + 4] | (uint32_t)in[i + 5] << 8 | (uint32_t)in[i + 6] << 16 |
                       (uint32_t)in[i + 7] << 24;
        if (clen < 4 || clen > n - i - 4)
            goto done;
        if (pos + raw > start) {
            const uint8_t *src = in + i + 8;
            size_t slen = clen - 4;
            if (pos >= start && pos + raw <= end) {
                if (nframes == cap) {
                    cap = cap ? cap * 2 : 64;
                    lzframe *p = realloc(J.frames, cap * sizeof *p);
                    if (!p)
                        goto done;
                    J.frames = p;
                }
                J.frames[nframes++] = (lzframe){ src, slen, out + (pos - start), raw };
            } else {
                if (raw > A_CHUNK_LIMIT)
                    goto done;
                uint8_t *tmp = malloc(raw ? raw : 1);
                if (!tmp || fq_lz4_decode(src, slen, tmp, raw)) {
                    free(tmp);
                    goto done;
                }
                int64_t a = pos > start ? pos : start, b = pos + raw < end ? pos + raw : end;
                memcpy(out + (a - start), tmp + (a - pos), (size_t)(b - a));
                free(tmp);
            }
        }
        pos += raw;
        i += 4 + (int64_t)clen;
    }
    fqi_par_for(nframes, threads, &J, lz4_task);
    rc = J.failed ? -1 : 0;
 done:
    free(J.frames);
    return rc;
}

static int zlib_range(const uint8_t *in, int64_t n, int64_t start, int64_t len, uint8_t *out)
{
    z_stream z;
    memset(&z, 0, sizeof z);
    if (inflateInit2(&z, 15 + 32) != Z_OK)
        return -1;
    uint8_t *scratch = malloc(1 << 16);
    int64_t pos = 0, end = start + len, fed = 0;
    while (scratch && pos < end) {
        if (z.avail_in == 0 && fed < n) {
            int64_t k = n - fed < (1 << 30) ? n - fed : (1 << 30);
            z.next_in = (Bytef *)(in + fed);
            z.avail_in = (uInt)k;
            fed += k;
        }
        int64_t room = pos < start ? start - pos : end - pos;
        if (pos < start && room > (1 << 16))
            room = 1 << 16;
        if (room > (1 << 30))
            room = 1 << 30;
        z.next_out = pos < start ? scratch : out + (pos - start);
        z.avail_out = (uInt)room;
        int rc = inflate(&z, Z_NO_FLUSH);
        pos += room - (int64_t)z.avail_out;
        if (rc != Z_OK)
            break;
    }
    inflateEnd(&z);
    free(scratch);
    return pos >= end ? 0 : -1;
}

static int bzip2_range(const uint8_t *in, int64_t n, int64_t start, int64_t len, uint8_t *out)
{
    bz_stream z;
    memset(&z, 0, sizeof z);
    if (BZ2_bzDecompressInit(&z, 0, 0) != BZ_OK)
        return -1;
    char *scratch = malloc(1 << 16);
    int64_t pos = 0, end = start + len, fed = 0;
    while (scratch && pos < end) {
        if (z.avail_in == 0 && fed < n) {
            int64_t k = n - fed < (1 << 30) ? n - fed : (1 << 30);
            z.next_in = (char *)(in + fed);
            z.avail_in = (unsigned)k;
            fed += k;
        }
        int64_t room = pos < start ? start - pos : end - pos;
        if (pos < start && room > (1 << 16))
            room = 1 << 16;
        if (room > (1 << 30))
            room = 1 << 30;
        z.next_out = pos < start ? scratch : (char *)out + (pos - start);
        z.avail_out = (unsigned)room;
        unsigned before_in = z.avail_in;
        int rc = BZ2_bzDecompress(&z);
        pos += room - (int64_t)z.avail_out;
        if (rc != BZ_OK || (z.avail_out == (unsigned)room && z.avail_in == before_in && fed >= n))
            break;
    }
    BZ2_bzDecompressEnd(&z);
    free(scratch);
    return pos >= end ? 0 : -1;
}

static int block_range(const fq_file *f, const ablock *b, int64_t start, int64_t len, uint8_t *out,
                       int threads)
{
    const uint8_t *in = f->data + b->data_off;
    if (!b->comp[0]) {
        memcpy(out, in + start, (size_t)len);
        return 0;
    }
    if (!strcmp(b->comp, "lz4"))
        return lz4_range(in, b->used, start, len, out, threads);
    if (!strcmp(b->comp, "zlib"))
        return zlib_range(in, b->used, start, len, out);
    return bzip2_range(in, b->used, start, len, out);
}

int fqi_asdf_load(fq_file *f, hdu_t *h, int64_t plane, int threads, const uint8_t **data,
                  int *big_endian, int64_t *avail, char *err, size_t errlen)
{
    fqi_asdf *a = f->asdf;
    const fqi_asdf_array *nd = h->asdf;
    if (nd->error[0] || !nd->listed) {
        fqi_seterr(err, errlen, "%s", nd->error[0] ? nd->error : "no array to show");
        return -1;
    }
    const ablock *b = &a->blocks[nd->source];
    int k = nd->nshape;
    int64_t W = nd->shape[k - 1], H = k > 1 ? nd->shape[k - 2] : 1;
    int64_t sx = nd->strides[k - 1], sy = k > 1 ? nd->strides[k - 2] : 0;
    int64_t bytes = fqi_mul_sat(fqi_mul_sat(W, H), nd->size);
    *big_endian = nd->big;
    *avail = bytes;
    /* Where the plane starts: its index on the outer axes. */
    int64_t base = nd->offset, rest = plane;
    for (int i = k - 3; i >= 0; i--) {
        base += (rest % nd->shape[i]) * nd->strides[i];
        rest /= nd->shape[i];
    }
    int dense = contiguous(nd);
    if (!b->comp[0] && dense) {
        *data = f->data + b->data_off + base;
        return 0;
    }
    if (a->decoded && a->decoded_array == nd && a->decoded_plane == plane) {
        *data = a->decoded;
        return 0;
    }
    free(a->decoded);
    a->decoded = NULL;
    if (bytes > A_DECODE_LIMIT) {
        fqi_seterr(err, errlen, "ASDF plane exceeds the 512 MiB decompression limit");
        return -1;
    }
    uint8_t *buf = malloc((size_t)bytes);
    if (!buf) {
        fqi_seterr(err, errlen, "out of memory");
        return -1;
    }
    if (dense) {
        if (block_range(f, b, base, bytes, buf, threads)) {
            free(buf);
            fqi_seterr(err, errlen, "ASDF: invalid or truncated compressed block %lld", (long long)nd->source);
            return -1;
        }
    } else {
        /* A view (strides of its own): the bytes it spans, then its
           elements in order. */
        int64_t count[FQ_MAXAXES] = { 0 };
        for (int i = 0; i < k; i++)
            count[i] = i >= k - 2 ? nd->shape[i] : 1;
        int64_t lo, hi;
        reach(nd, count, base, &lo, &hi);
        const uint8_t *src;
        uint8_t *span = NULL;
        if (!b->comp[0]) {
            src = f->data + b->data_off + lo;
        } else {
            if (hi - lo > A_DECODE_LIMIT || !(span = malloc((size_t)(hi - lo))) ||
                block_range(f, b, lo, hi - lo, span, threads)) {
                free(span);
                free(buf);
                fqi_seterr(err, errlen, "ASDF: cannot read block %lld for this view", (long long)nd->source);
                return -1;
            }
            src = span;
        }
        uint8_t *o = buf;
        for (int64_t y = 0; y < H; y++)
            for (int64_t x = 0; x < W; x++, o += nd->size)
                memcpy(o, src + (base - lo) + y * sy + x * sx, (size_t)nd->size);
        free(span);
    }
    a->decoded = buf;
    a->decoded_array = nd;
    a->decoded_plane = plane;
    *data = buf;
    return 0;
}
