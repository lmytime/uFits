#!/usr/bin/env python3
"""Throw damaged FITS and XISF files at fqtool and make sure it never crashes.

Usage: fuzz.py FQTOOL TESTDATA_DIR [ITERATIONS]

Build fqtool with -fsanitize=address,undefined to catch memory errors that
do not crash outright. Mutations: random byte flips in the header and data,
truncation, edited keyword values, swapped header blocks, odd header cards.
"""
import os
import random
import re
import subprocess
import sys
import tempfile

FQ, DATA = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 300
rnd = random.Random(int(os.environ.get("FUZZ_SEED", "1234")))

KEYS = [b"BITPIX  =", b"NAXIS   =", b"NAXIS1  =", b"NAXIS2  =", b"NAXIS3  =", b"PCOUNT  =",
        b"ZNAXIS1 =", b"ZNAXIS2 =", b"ZTILE1  =", b"ZTILE2  =", b"ZBITPIX =", b"TFORM1  =",
        b"ZVAL1   =", b"ZVAL2   =", b"BLANK   =", b"BSCALE  =", b"THEAP   =", b"NAXIS1  =",
        b"TFIELDS =", b"TFORM2  =", b"TFORM3  =", b"TBCOL2  =", b"TSCAL2  =", b"TNULL2  ="]
VALUES = [b"0", b"-1", b"1", b"2", b"3", b"7", b"-32", b"64", b"999999999", b"-2147483648",
          b"9223372036854775807", b"1E300", b"'1PB(0)'", b"'1QB(99999999)'", b"'abc'", b"T",
          b"'1000000D'", b"'E'", b"'0J'", b"'F99999.3'", b"'A0'", b"'2X'", b"'3M'", b"'PE()'"]
# Header cards that are hard to split into key, value and comment.
CARDS = [b"CONTINUE  'abc&'", b"CONTINUE  '&", b"CONTINUE  ", b"LONG    = 'abc&'", b"LONG    = '&'",
         b"LONG    = '" + b"x" * 69, b"HIERARCH " + b"A" * 71, b"HIERARCH =", b"HIERARCH A B = 'x''",
         b"HIERARCH" + b"=" * 72, b"QUOTE   = " + b"'" * 15, b"SLASH   = //////////", b"'" * 80, b"=" * 80,
         b"COMMENT " + b"\t\x00\xff" * 24, b"KEY     =", b"KEY     = '", b"        = 'x' / y", b"END"]


def mutate_xisf(data):
    d = bytearray(data)
    end = min(len(d), 16 + int.from_bytes(d[8:12], "little"))
    kind = rnd.randrange(6)
    if kind == 0:   # malformed XML, including non-UTF-8 bytes
        for _ in range(rnd.randrange(1, 30)):
            d[rnd.randrange(16, end)] = rnd.randrange(256)
    elif kind == 1:  # inconsistent or oversized XML header length
        d[8:12] = rnd.choice([0, 1, 15, len(d), 0x7fffffff, 0xffffffff]).to_bytes(4, "little")
    elif kind == 2:  # corrupt attached compressed/pixel data
        match = re.search(br'location="attachment:(\d+):', d[16:end])
        start = min(len(d) - 1, int(match[1]) if match else end)
        for _ in range(rnd.randrange(1, 100)):
            d[rnd.randrange(start, len(d))] = rnd.randrange(256)
    elif kind == 3:
        d = d[:rnd.randrange(1, len(d))]
    elif kind == 4:  # mutate attribute values without shifting attachment offsets
        attrs = list(re.finditer(br'(?:geometry|sampleFormat|location|compression|subblocks|byteOrder)="([^"]*)"',
                                 d[16:end]))
        if attrs:
            attr = rnd.choice(attrs)
            a, b = (16 + v for v in attr.span(1))
            value = rnd.choice([b"0", b"-1", b"9223372036854775807", b"unknown", b"0:0:0", b"1,0:0,1"])
            d[a:b] = value.ljust(b - a)[:b - a]
    else:
        a = rnd.randrange(16, len(d))
        b = min(len(d), a + rnd.randrange(1, 1000))
        d[a:b] = bytes(b - a)
    return bytes(d)


def mutate(data):
    if data.startswith(b"XISF0100"):
        return mutate_xisf(data)
    d = bytearray(data)
    kind = rnd.randrange(7)
    if kind == 0:   # flip bytes anywhere
        for _ in range(rnd.randrange(1, 50)):
            d[rnd.randrange(len(d))] = rnd.randrange(256)
    elif kind == 1:  # flip bytes in the data part only (compressed streams)
        start = min(len(d) - 1, 2880 * 2)
        for _ in range(rnd.randrange(1, 200)):
            d[rnd.randrange(start, len(d))] = rnd.randrange(256)
    elif kind == 2:  # truncate
        d = d[: rnd.randrange(1, len(d))]
    elif kind == 3:  # rewrite a keyword value
        key = rnd.choice(KEYS)
        pos = d.find(key)
        if pos >= 0:
            val = rnd.choice(VALUES)
            field = val.rjust(20) if not val.startswith(b"'") else val.ljust(20)
            d[pos + 10:pos + 30] = field[:20]
    elif kind == 4:  # duplicate a header block
        if len(d) > 2880 * 2:
            b = rnd.randrange(len(d) // 2880)
            d[2880:2880] = d[b * 2880:(b + 1) * 2880]
    elif kind == 5:  # odd cards in the first header, often several in a row
        at = rnd.randrange(min(len(d), 2880) // 80) * 80
        for _ in range(rnd.randrange(1, 6)):
            d[at:at + 80] = rnd.choice(CARDS).ljust(80)[:80]
            at += 80
    else:            # zero a random span
        a = rnd.randrange(len(d))
        b = min(len(d), a + rnd.randrange(1, 20000))
        d[a:b] = bytes(b - a)
    return bytes(d)


def main():
    files = [os.path.join(DATA, f) for f in sorted(os.listdir(DATA))
             if f.endswith((".fits", ".xisf")) and os.path.getsize(os.path.join(DATA, f)) < 2_000_000]
    bad, xisf_count = 0, 0
    env = dict(os.environ, ASAN_OPTIONS=f"detect_leaks={int(sys.platform != 'darwin')}:abort_on_error=0",
               UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1")
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "o.png")
        for it in range(N):
            src = rnd.choice(files)
            suffix = os.path.splitext(src)[1]
            xisf_count += suffix == ".xisf"
            target = os.path.join(tmp, "m" + suffix)
            data = mutate(open(src, "rb").read())
            open(target, "wb").write(data)
            region = ",".join(str(rnd.choice([-50, 0, 3, 17, 200, 5000])) for _ in range(4))
            for args in (["render", target, png, "--max", str(rnd.choice([16, 100, 512])),
                          "--samples", str(rnd.choice([0, 1, 2, 4]))],
                         ["render", target, png, "--max", str(rnd.choice([16, 100, 512])), "--region", region],
                         ["info", target],
                         ["header", target, str(rnd.randrange(3))] + rnd.choice([[], ["--cards"], ["--spans"]]),
                         ["hdus", target], ["table", target, str(rnd.randrange(1, 3)), "50"],
                         ["rows", target, str(rnd.randrange(1, 3)), str(rnd.choice([0, 3, 999])), "5"]):
                try:
                    r = subprocess.run([FQ, *args], capture_output=True, text=True, errors="replace",
                                       env=env, timeout=30)
                except subprocess.TimeoutExpired:
                    bad += 1
                    keep = os.path.join(os.path.dirname(FQ), f"hang_{it}{suffix}")
                    open(keep, "wb").write(data)
                    print(f"HANG {os.path.basename(src)} {' '.join(args[:1] + args[3:])} -> {keep}")
                    break
                if r.returncode not in (0, 1) or "ERROR: AddressSanitizer" in r.stderr \
                        or "runtime error" in r.stderr or "LeakSanitizer" in r.stderr:
                    bad += 1
                    keep = os.path.join(os.path.dirname(FQ), f"crash_{it}{suffix}")
                    open(keep, "wb").write(data)
                    print(f"CRASH {os.path.basename(src)} {args[0]} rc={r.returncode} -> {keep}")
                    print(r.stderr[-3000:])
                    break
    print(f"{N} mutated files ({xisf_count} XISF), {bad} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
