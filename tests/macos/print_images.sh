#!/bin/sh
# Print small JPEG copies of the PNGs in a directory as base64 chunks, so the
# images can be recovered from a CI log: lines look like "IMG name index data".
for f in "$1"/*.png; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in app-*) size=1100 ;; *) size=420 ;; esac
    sips -s format jpeg -s formatOptions 70 -Z $size "$f" --out "$f.jpg" > /dev/null 2>&1 || continue
    base64 -i "$f.jpg" | tr -d '\n' | fold -w 3000 | awk -v n="$(basename "$f")" '{print "IMG", n, NR, $0}'
done
