#!/usr/bin/env python3
"""Throw damaged FITS files at fqtool and make sure it never crashes.

Usage: fuzz.py FQTOOL TESTDATA_DIR [ITERATIONS]

Build fqtool with -fsanitize=address,undefined to catch memory errors that
do not crash outright. Mutations: random byte flips in the header and data,
truncation, edited keyword values, swapped header blocks.
"""
import os
import random
import subprocess
import sys
import tempfile

FQ, DATA = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 300
rnd = random.Random(1234)

KEYS = [b"BITPIX  =", b"NAXIS   =", b"NAXIS1  =", b"NAXIS2  =", b"NAXIS3  =", b"PCOUNT  =",
        b"ZNAXIS1 =", b"ZNAXIS2 =", b"ZTILE1  =", b"ZTILE2  =", b"ZBITPIX =", b"TFORM1  =",
        b"ZVAL1   =", b"ZVAL2   =", b"BLANK   =", b"BSCALE  =", b"THEAP   =", b"NAXIS1  ="]
VALUES = [b"0", b"-1", b"1", b"2", b"3", b"7", b"-32", b"64", b"999999999", b"-2147483648",
          b"9223372036854775807", b"1E300", b"'1PB(0)'", b"'1QB(99999999)'", b"'abc'", b"T"]


def mutate(data):
    d = bytearray(data)
    kind = rnd.randrange(6)
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
    else:            # zero a random span
        a = rnd.randrange(len(d))
        b = min(len(d), a + rnd.randrange(1, 20000))
        d[a:b] = bytes(b - a)
    return bytes(d)


def main():
    files = [os.path.join(DATA, f) for f in sorted(os.listdir(DATA))
             if f.endswith(".fits") and os.path.getsize(os.path.join(DATA, f)) < 2_000_000]
    bad = 0
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:abort_on_error=0",
               UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1")
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "m.fits")
        png = os.path.join(tmp, "o.png")
        for it in range(N):
            src = rnd.choice(files)
            data = mutate(open(src, "rb").read())
            open(target, "wb").write(data)
            for args in (["render", target, png, "--max", str(rnd.choice([16, 100, 512])),
                          "--samples", str(rnd.choice([0, 1, 2, 4]))],
                         ["info", target], ["header", target, str(rnd.randrange(3))]):
                try:
                    r = subprocess.run([FQ, *args], capture_output=True, text=True, errors="replace",
                                       env=env, timeout=30)
                except subprocess.TimeoutExpired:
                    bad += 1
                    keep = os.path.join(os.path.dirname(FQ), f"hang_{it}.fits")
                    open(keep, "wb").write(data)
                    print(f"HANG {os.path.basename(src)} {' '.join(args[:1] + args[3:])} -> {keep}")
                    break
                if r.returncode not in (0, 1) or "ERROR: AddressSanitizer" in r.stderr \
                        or "runtime error" in r.stderr or "LeakSanitizer" in r.stderr:
                    bad += 1
                    keep = os.path.join(os.path.dirname(FQ), f"crash_{it}.fits")
                    open(keep, "wb").write(data)
                    print(f"CRASH {os.path.basename(src)} {args[0]} rc={r.returncode} -> {keep}")
                    print(r.stderr[-3000:])
                    break
    print(f"{N} mutated files, {bad} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
