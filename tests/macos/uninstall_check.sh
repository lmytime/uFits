#!/bin/sh
# Uninstalls uFits (install.sh --uninstall) and checks that nothing of it
# is left: no app, no Quick Look extension registered (from any copy), no
# launchd job, nothing running, no settings, and no file or folder named
# after it in ~/Library or the user's temporary and cache folders (crash
# reports aside: macOS keeps those).
#
#   tests/macos/uninstall_check.sh
set -u

sh "$(dirname "$0")/../../install.sh" --uninstall || { echo "FAIL the uninstaller failed"; exit 1; }

fail=0
check() {
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
check "no uFits in /Applications or ~/Applications" '[ ! -e /Applications/uFits.app ] && [ ! -e "$HOME/Applications/uFits.app" ]'
check "no launchd job" '[ ! -e "$HOME/Library/LaunchAgents/io.github.lmytime.uFits.update.plist" ] &&
    ! launchctl print "gui/$(id -u)/io.github.lmytime.uFits.update" > /dev/null 2>&1'
check "nothing of uFits runs" '! pgrep -l -f "uFits.app/Contents/" > /dev/null'
for id in Preview Thumbnail; do
    check "no $id extension registered, from any copy" \
        '! pluginkit -m -A -D -v -i io.github.lmytime.uFits.$id 2> /dev/null | grep -q lmytime'
done
check "no settings" '! defaults read io.github.lmytime.uFits > /dev/null 2>&1'
user=$(dirname "$(getconf DARWIN_USER_DIR)")
left=$(find "$HOME/Library" "$user" -maxdepth 4 \( -iname '*lmytime*' -o -iname '*ufits*' \) \
    -not -path '*/DiagnosticReports/*' 2> /dev/null)
check "no file of uFits left in ~/Library or $user" '[ -z "$left" ]'
[ -z "$left" ] || printf '%s\n' "$left" | sed 's/^/     /'
exit $fail
