#!/bin/sh
# Ask Quick Look (through the installed uFits extensions) for thumbnails of a
# few test files and check that they look like ours: the generic document
# icon is square, our thumbnails keep the image's aspect ratio.
#
# Usage: tests/ql_smoke.sh TESTDATA_DIR OUT_DIR
set -u
data=$1
out=$2
mkdir -p "$out"
fail=0
check() {   # file expected-aspect(landscape|square-ok)
    f=$1
    qlmanage -t -s 256 -o "$out" "$data/$f" > "$out/$f.log" 2>&1
    png="$out/$f.png"
    if [ ! -f "$png" ]; then
        echo "FAIL $f: no thumbnail"; cat "$out/$f.log"; fail=1; return
    fi
    w=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')
    if [ "$2" = landscape ] && [ "$w" -le "$h" ]; then
        echo "FAIL $f: ${w}x${h}, looks like a generic icon"; fail=1; return
    fi
    echo "ok   $f: ${w}x${h}"
}
check f32.fits landscape
check rgb.fits landscape
check bayer_rggb.fits landscape
check rice_f32_sd1.fits landscape
check footprint_f32.fits landscape
check mef.fits square-ok
check spec1d.fits landscape
exit $fail
