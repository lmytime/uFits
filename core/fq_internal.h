/*
 * fq_internal.h - pieces shared between fq.c and fq_codec.c.
 */
#ifndef FQ_INTERNAL_H
#define FQ_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#error "uFits assumes a little-endian host"
#endif

static inline uint16_t fq_be16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return __builtin_bswap16(v); }
static inline uint32_t fq_be32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return __builtin_bswap32(v); }
static inline uint64_t fq_be64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return __builtin_bswap64(v); }

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
