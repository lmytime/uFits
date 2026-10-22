#!/bin/sh
# Big files: what is shown is read, not the whole file. Sparse files (no
# disk space) of a 4 GiB cube, a 2 GiB image and a 64 GiB catalog; a plane
# of the cube, a second plane, a zoomed-in part of the image and the map of
# the catalog (sampled in windows) must each be quick. Then,
# for the record, how long macOS takes to answer a read-ahead hint over the
# 2 GiB image: since macOS 15.4 it faults in every page of the range, which
# is why the core hints only the rows it reads.
#
#   tests/macos/bigfile_check.sh FQTOOL OUTDIR
set -u

fq=$1
out=$2
mkdir -p "$out"
cube=$out/big_cube.fits
wide=$out/big_wide.fits
cat=$out/big_cat.fits

python3 - "$cube" "$wide" "$cat" << 'EOF'
import sys

def header(cards):
    head = b"".join(f"{k:<8}= {v:>20}".encode().ljust(80) for k, v in cards) + b"END".ljust(80)
    return head.ljust(-(-len(head) // 2880) * 2880, b" ")

def write(path, heads, nbytes):
    head = b"".join(header(cards) for cards in heads)
    with open(path, "wb") as f:
        f.write(head)
        f.truncate(len(head) + -(-nbytes // 2880) * 2880)

write(sys.argv[1], [[("SIMPLE", "T"), ("BITPIX", -32), ("NAXIS", 3), ("NAXIS1", 4096), ("NAXIS2", 4096),
                     ("NAXIS3", 64)]], 4096 * 4096 * 64 * 4)
write(sys.argv[2], [[("SIMPLE", "T"), ("BITPIX", -32), ("NAXIS", 2), ("NAXIS1", 65536), ("NAXIS2", 8192)]],
      65536 * 8192 * 4)
rows = (64 << 30) // 16
write(sys.argv[3], [[("SIMPLE", "T"), ("BITPIX", 8), ("NAXIS", 0), ("EXTEND", "T")],
                    [("XTENSION", "'BINTABLE'"), ("BITPIX", 8), ("NAXIS", 2), ("NAXIS1", 16), ("NAXIS2", rows),
                     ("PCOUNT", 0), ("GCOUNT", 1), ("TFIELDS", 2), ("TTYPE1", "'RA      '"),
                     ("TFORM1", "'D       '"), ("TTYPE2", "'DEC     '"), ("TFORM2", "'D       '")]],
      rows * 16)
EOF

fail=0
# Milliseconds that fqtool render reports, or 99999.
render() {
    "$fq" render "$@" 2> /dev/null | sed -n 's/.*render \([0-9.]*\) ms.*/\1/p' | head -1 | grep . || echo 99999
}
check() {   # name, ms, limit
    if awk -v t="$2" -v l="$3" 'BEGIN { exit !(t < l) }'; then
        printf 'ok   %-46s %8.1f ms\n' "$1" "$2"
    else
        printf 'FAIL %-46s %8.1f ms (limit %s ms)\n' "$1" "$2" "$3"
        fail=1
    fi
}
check "a plane of a 4 GiB cube (preview)" "$(render "$cube" "$out/cube.png" --max 2560 --samples 4)" 800
check "another plane of it" "$(render "$cube" "$out/cube5.png" --max 2560 --samples 4 --plane 5)" 800
check "a zoomed-in part of a 2 GiB image" \
    "$(render "$wide" "$out/wide.png" --max 1024 --samples 1 --region 30000,4000,1000,800)" 800
check "the map of a 64 GiB catalog" "$(render "$cat" "$out/cat.png" --max 1024)" 2000

cc -O2 -x c -o "$out/willneed" - << 'EOF'
#include <fcntl.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0)
        return 1;
    void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (m == MAP_FAILED)
        return 1;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    posix_madvise(m, (size_t)st.st_size, POSIX_MADV_WILLNEED);
    clock_gettime(CLOCK_MONOTONIC, &b);
    printf("%.0f ms\n", (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6);
    return 0;
}
EOF
echo "info read-ahead hint over 2 GiB on macOS $(sw_vers -productVersion 2> /dev/null): $("$out/willneed" "$wide")"
rm -f "$cube" "$wide" "$cat"
exit $fail
