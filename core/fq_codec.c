/*
 * fq_codec.c - decoders for FITS tiled image compression.
 *
 * RICE_1, GZIP_1, GZIP_2 and PLIO_1, written from the format descriptions
 * in the FITS standard (section 10) and Pence et al. 2009. Every decoder
 * checks its input bounds: a damaged file gives an error, never a crash.
 */
#include "fq_internal.h"

#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

/* ---- MSB-first bit reader ---------------------------------------------- */

typedef struct {
    const uint8_t *p, *end;
    uint64_t buf;    /* unread bits, left aligned; bits past n are zero */
    int n;           /* number of unread bits in buf */
    uint64_t used;   /* bits consumed */
    uint64_t avail;  /* bits in the input */
} bitreader;

static inline void br_init(bitreader *b, const uint8_t *p, size_t len)
{
    b->p = p;
    b->end = p + len;
    b->buf = 0;
    b->n = 0;
    b->used = 0;
    b->avail = (uint64_t)len * 8;
}

static inline void br_fill(bitreader *b)
{
    if (b->end - b->p >= 8) {
        /* Top up with whole bytes from one 64 bit load, then clear the
           bits beyond n so the "past n is zero" rule still holds. */
        int nbytes = (63 - b->n) >> 3;
        b->buf |= fq_be64(b->p) >> b->n;
        b->p += nbytes;
        b->n += nbytes * 8;
        b->buf &= ~(~(uint64_t)0 >> b->n);
        return;
    }
    while (b->n <= 56) {
        uint64_t byte = 0;
        if (b->p < b->end)
            byte = *b->p++;
        b->buf |= byte << (56 - b->n);
        b->n += 8;
    }
}

/* Read 1..32 bits. */
static inline uint32_t br_get(bitreader *b, int nbits)
{
    if (b->n < nbits)
        br_fill(b);
    uint32_t v = (uint32_t)(b->buf >> (64 - nbits));
    b->buf <<= nbits;
    b->n -= nbits;
    b->used += (uint64_t)nbits;
    return v;
}

/* Count zero bits up to the next one bit and consume both. */
static inline int br_unary(bitreader *b, uint32_t *count)
{
    uint32_t c = 0;
    for (;;) {
        if (b->n == 0)
            br_fill(b);
        if (b->buf != 0) {
            int lz = __builtin_clzll(b->buf);
            int k = lz + 1;
            c += (uint32_t)lz;
            b->buf = k >= 64 ? 0 : b->buf << k;
            b->n -= k;
            b->used += (uint64_t)k;
            *count = c;
            return 0;
        }
        c += (uint32_t)b->n;
        b->used += (uint64_t)b->n;
        b->n = 0;
        if (b->used > b->avail)
            return -1;
    }
}

/* ---- RICE_1 --------------------------------------------------------------- */

int fq_rice_decode(const uint8_t *in, size_t inlen, int32_t *out, int64_t npix,
                   int blocksize, int bytepix)
{
    int fsbits, fsmax;
    uint32_t mask;
    switch (bytepix) {
    case 1: fsbits = 3; fsmax = 6; mask = 0xffu; break;
    case 2: fsbits = 4; fsmax = 14; mask = 0xffffu; break;
    default: bytepix = 4; fsbits = 5; fsmax = 25; mask = 0xffffffffu; break;
    }
    const int bbits = 1 << fsbits;
    if (blocksize <= 0)
        blocksize = 32;
    if (inlen < (size_t)bytepix)
        return -1;

    /* The first pixel is stored verbatim, big-endian. */
    uint32_t last = 0;
    for (int i = 0; i < bytepix; i++)
        last = (last << 8) | in[i];

    bitreader br;
    br_init(&br, in + bytepix, inlen - (size_t)bytepix);

    /* Values are rebuilt as unsigned sums wrapped to the pixel width;
       16 bit pixels get their sign back at the end. */
    uint32_t *u = (uint32_t *)out;
    int64_t i = 0;
    while (i < npix) {
        int fs = (int)br_get(&br, fsbits) - 1;
        int64_t imax = i + blocksize;
        if (imax > npix)
            imax = npix;
        if (fs < 0) {
            /* Every difference in the block is zero. */
            for (; i < imax; i++)
                u[i] = last;
        } else if (fs == fsmax) {
            /* High entropy block: differences stored directly. */
            for (; i < imax; i++) {
                uint32_t d = br_get(&br, bbits);
                d = (d & 1) ? ~(d >> 1) : (d >> 1);
                last = (last + d) & mask;
                u[i] = last;
            }
        } else if (fs > fsmax) {
            return -1;
        } else {
            for (; i < imax; i++) {
                uint32_t nz;
                if (br_unary(&br, &nz) != 0)
                    return -1;
                uint32_t d = fs ? (nz << fs) | br_get(&br, fs) : nz;
                d = (d & 1) ? ~(d >> 1) : (d >> 1);
                last = (last + d) & mask;
                u[i] = last;
            }
        }
        if (br.used > br.avail)
            return -1;
    }
    if (bytepix == 2)
        for (i = 0; i < npix; i++)
            out[i] = (int16_t)(uint16_t)u[i];
    return 0;
}

/* ---- PLIO_1 --------------------------------------------------------------- */

/*
 * A PLIO line list is a short header followed by 16 bit instructions:
 * the top 3 bits are an opcode, the low 12 bits an argument. The decoder
 * walks the instructions keeping a current value and an output position.
 */
int fq_plio_decode(const int16_t *ll, size_t nwords, int32_t *out, int64_t npix)
{
    if (nwords < 3 || npix <= 0)
        return -1;
    int64_t len, first;
    if (ll[2] > 0) {                  /* old style header */
        len = ll[2];
        first = 3;
    } else {
        if (nwords < 5)
            return -1;
        len = (int64_t)ll[4] * 32768 + ll[3];
        first = ll[1];
    }
    if (len > (int64_t)nwords)
        len = (int64_t)nwords;
    if (first < 0)
        return -1;

    int64_t x1 = 1, op = 0, pv = 1;   /* x positions are 1-based */
    const int64_t xe = npix;
    for (int64_t ip = first; ip < len && x1 <= xe; ip++) {
        int w = ll[ip];
        if (w < 0)
            continue;
        int opcode = w >> 12, data = w & 4095;
        switch (opcode) {
        case 0: case 4: case 5: {     /* run of zeros or of the current value */
            int64_t x2 = x1 + data - 1;
            int64_t i1 = x1 < 1 ? 1 : x1;
            int64_t i2 = x2 > xe ? xe : x2;
            int64_t np = i2 - i1 + 1;
            if (np > 0) {
                if (op + np > npix)
                    np = npix - op;
                int32_t v = opcode == 4 ? (int32_t)pv : 0;
                for (int64_t k = 0; k < np; k++)
                    out[op + k] = v;
                op += np;
                if (opcode == 5 && i2 == x2 && op > 0)
                    out[op - 1] = (int32_t)pv;
            }
            x1 = x2 + 1;
            break;
        }
        case 1:                        /* set the value, high bits in next word */
            if (ip + 1 >= len)
                return -1;
            pv = (int64_t)ll[ip + 1] * 4096 + data;
            ip++;
            break;
        case 2: pv += data; break;
        case 3: pv -= data; break;
        case 6:
        case 7:                        /* adjust the value and emit one pixel */
            pv += opcode == 6 ? data : -data;
            if (x1 >= 1 && x1 <= xe && op < npix)
                out[op++] = (int32_t)pv;
            x1++;
            break;
        }
    }
    for (; op < npix; op++)
        out[op] = 0;
    return 0;
}

/* ---- GZIP ----------------------------------------------------------------- */

int64_t fq_inflate(const uint8_t *in, size_t inlen, uint8_t *out, size_t outcap)
{
    z_stream z;
    memset(&z, 0, sizeof z);
    if (inflateInit2(&z, 15 + 32) != Z_OK) /* accept gzip and zlib headers */
        return -1;
    size_t inpos = 0, outpos = 0;
    int rc = Z_OK;
    for (;;) {
        size_t inchunk = inlen - inpos, outchunk = outcap - outpos;
        if (inchunk > UINT_MAX) inchunk = UINT_MAX;
        if (outchunk > UINT_MAX) outchunk = UINT_MAX;
        z.next_in = (Bytef *)(in + inpos);
        z.avail_in = (uInt)inchunk;
        z.next_out = out + outpos;
        z.avail_out = (uInt)outchunk;
        rc = inflate(&z, Z_NO_FLUSH);
        inpos += inchunk - z.avail_in;
        outpos += outchunk - z.avail_out;
        if (rc == Z_STREAM_END) {
            /* Concatenated gzip members continue the stream. */
            if (inlen - inpos >= 2 && in[inpos] == 0x1f && in[inpos + 1] == 0x8b &&
                outpos < outcap) {
                inflateReset(&z);
                continue;
            }
            break;
        }
        if (rc != Z_OK || outpos == outcap || (z.avail_in == 0 && inpos == inlen))
            break;
    }
    inflateEnd(&z);
    if (rc != Z_STREAM_END && rc != Z_OK && rc != Z_BUF_ERROR)
        return -1;
    return (int64_t)outpos;
}

void fq_unshuffle(const uint8_t *in, uint8_t *out, int64_t n, int itemsize)
{
    for (int b = 0; b < itemsize; b++) {
        const uint8_t *src = in + (int64_t)b * n;
        uint8_t *dst = out + b;
        for (int64_t i = 0; i < n; i++)
            dst[i * itemsize] = src[i];
    }
}
