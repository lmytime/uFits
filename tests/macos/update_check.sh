#!/bin/sh
# Updates the uFits in /Applications to release VERSION as a user would, and
# checks that it worked:
#
#   tests/macos/update_check.sh VERSION [PICTURES]
#
# The uFits there must be older than VERSION, and VERSION published. uFits
# is opened; when it does not offer the update by itself, uFits › Check for
# Updates… asks for it; Update is clicked (System Events clicks for the
# user). Then VERSION must be in /Applications and running, the old copy
# gone, and Quick Look and the launchd job must use the new copy. PICTURES,
# if given, gets app-update-offer.png and app-updated.png.
set -eu

want=$1
pics=${2:-}
app=/Applications/uFits.app

version() { plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || true; }

# Whether a window of uFits has a button named $1; clicks it with --click.
button() {
    osascript -e 'on run {b, act}' -e 'tell application "System Events" to tell process "uFits"' \
        -e 'repeat with w in windows' -e 'if exists button b of w then' \
        -e 'if act is "--click" then click button b of w' -e 'return' -e 'end if' -e 'end repeat' \
        -e 'end tell' -e 'error "no button " & b' -e 'end run' "$1" "${2:-}" > /dev/null 2>&1
}

picture() { [ -z "$pics" ] || screencapture -x "$pics/$1" || true; }

pkill -x uFits 2> /dev/null || true
sleep 1
echo "uFits $(version) in $app, to be updated to $want"
open "$app"
old=
for i in $(seq 1 20); do
    old=$(pgrep -x uFits || true)
    [ -z "$old" ] || break
    sleep 1
done
[ -n "$old" ] || { echo "FAIL uFits did not open"; exit 1; }

# uFits offers the update as it opens when it has seen the release out
# there; else it is asked to look.
offered=
for i in $(seq 1 10); do
    if button Update; then offered=1; break; fi
    sleep 1
done
if [ -z "$offered" ]; then
    echo "     (no offer yet: uFits › Check for Updates…)"
    osascript -e 'tell application "System Events" to tell process "uFits" to click menu item 2 of menu 1 of menu bar item 2 of menu bar 1' > /dev/null || true
    for i in $(seq 1 30); do
        if button Update; then offered=1; break; fi
        sleep 1
    done
fi
if [ -z "$offered" ]; then
    picture app-update-none.png
    echo "FAIL uFits did not offer $want"
    exit 1
fi
picture app-update-offer.png
button Update --click
t0=$(date +%s)

# Done when VERSION is in place and running, and the old copy has quit.
for i in $(seq 1 180); do
    if [ "$(version)" = "$want" ] && ! kill -0 "$old" 2> /dev/null && pgrep -x uFits > /dev/null; then
        break
    fi
    sleep 1
done
echo "     $(($(date +%s) - t0)) s after Update: uFits $(version) in $app"
sleep 3
picture app-updated.png

fail=0
check() {
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
running() { ps -o command= -p "$(pgrep -x uFits | head -1)" 2> /dev/null || true; }
check "uFits $want is in $app" '[ "$(version)" = "$want" ]'
check "the old uFits quit" '! kill -0 "$old" 2> /dev/null'
check "the new one runs (from $app)" 'running | grep -qF "$app/Contents/MacOS/uFits"'
check "its signature is whole" 'codesign --verify --deep --strict "$app" 2> /dev/null'
for id in Preview Thumbnail; do
    check "Quick Look has its $id extension" \
        'pluginkit -m -v -i io.github.lmytime.uFits.$id | grep -F "($want)" | grep -qF "$app/"'
done
check "the launchd job runs it" '[ "$(plutil -extract ProgramArguments.0 raw \
    "$HOME/Library/LaunchAgents/io.github.lmytime.uFits.update.plist" 2> /dev/null)" = "$app/Contents/MacOS/uFits" ]'
pkill -x uFits 2> /dev/null || true
exit $fail
