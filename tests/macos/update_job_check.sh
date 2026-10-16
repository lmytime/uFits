#!/bin/sh
# uFits 0.0.9 and earlier had launchd run uFits --check-for-updates-if-due
# every four hours, and macOS kept announcing that job as a new background
# item. Checks that the uFits in /Applications removes the job, set up as
# those versions did: when the job runs it, as the app opens, and as the
# installer puts it in place (from UFITS_DMG):
#
#   UFITS_DMG=build/uFits-X.dmg tests/macos/update_job_check.sh
set -u
: "${UFITS_DMG:?the disk image to install}"

app=/Applications/uFits.app
label=io.github.lmytime.uFits.update
job=$HOME/Library/LaunchAgents/$label.plist
service=gui/$(id -u)/$label

# The job as uFits 0.0.9 set it up, RunAtLoad aside: it runs when asked to.
old_job() {
    mkdir -p "$(dirname "$job")"
    cat > "$job" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/uFits</string>
        <string>--check-for-updates-if-due</string>
    </array>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$job"
}

# Whether the job is gone (its file, and from launchd) within $1 seconds.
gone() {
    for i in $(seq 1 "$1"); do
        if [ ! -e "$job" ] && ! launchctl print "$service" > /dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

fail=0
check() {
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
    launchctl bootout "$service" 2> /dev/null || true   # for the next check
    rm -f "$job"
}

pkill -x uFits 2> /dev/null || true
launchctl bootout "$service" 2> /dev/null || true
rm -f "$job"

old_job
launchctl kickstart "$service"
check "the job removes itself when it runs this uFits" 'gone 10'

old_job
open "$app"
check "the app removes it as it opens" 'gone 20'
osascript -e 'quit app "uFits"' > /dev/null 2>&1 || pkill -x uFits || true

old_job
sh "$(dirname "$0")/../../install.sh" > /dev/null
check "the installer removes it" 'gone 1'
exit $fail
