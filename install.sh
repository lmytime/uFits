#!/bin/sh
# Installs uFits (Quick Look previews and thumbnails for FITS files) in one go:
#
#   curl -fsSL https://github.com/lmytime/uFits/releases/latest/download/install.sh | sh
#
# It downloads the release's disk image, checks its SHA-256, copies uFits.app
# to /Applications (~/Applications when that is not writable) and turns on its
# Quick Look extensions. Nothing else to do: select a FITS file in Finder and
# press Space. Files fetched by curl are not quarantined, so macOS does not
# stop the app (releases are ad hoc signed, not notarized).
#
#   ... | sh -s -- --uninstall      removes uFits again
#
# Settings, from the environment:
#   UFITS_VERSION=0.0.1   install this release (default: the one this script
#                         came with, or the latest)
#   UFITS_DEST=folder     install into this folder
#   UFITS_DMG=file.dmg    install from this disk image, without downloading
#   UFITS_FROM_APP=1      leave uFits running (it runs this to update itself,
#                         and opens the new copy when this is done)
#
# When curl cannot download, the GitHub CLI is tried (a private copy of the
# repository needs it, signed in with gh auth login).
set -eu

REPO=lmytime/uFits
VERSION=${UFITS_VERSION:-@VERSION@}   # filled in when a release is published
APP=uFits.app
IDS="io.github.lmytime.uFits.Preview io.github.lmytime.uFits.Thumbnail"
AGENT=io.github.lmytime.uFits.update   # looks for a newer uFits (see the app)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TMP=
MNT=
mounted=0

say() { printf '%s\n' "$*"; }

fail() {
    printf 'uFits: %s\n' "$*" >&2
    exit 1
}

# Quits uFits and its extensions, if they are running.
stop() {
    [ -n "${UFITS_FROM_APP:-}" ] || pkill -x uFits 2>/dev/null || true
    pkill -x uFitsPreview 2>/dev/null || true
    pkill -x uFitsThumbnail 2>/dev/null || true
}

# Unregisters the app $1 and its extensions.
unregister() {
    [ -d "$1" ] || return 0
    for ext in "$1"/Contents/PlugIns/*.appex; do
        [ -d "$ext" ] && pluginkit -r "$ext" 2>/dev/null || true
    done
    "$LSREGISTER" -u "$1" 2>/dev/null || true
}

reset_quicklook() {
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
}

cleanup() {
    if [ "$mounted" = 1 ]; then
        hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true
    fi
    [ -z "$TMP" ] || rm -rf "$TMP"
}

hint="(is the Mac online?)"

# The release tag to install: VERSION, or the latest release when it is
# @VERSION@ (a copy of this script from the repository) or "latest".
release_tag() {
    v=${VERSION#v}
    case $v in
    [0-9]*)
        echo "v$v"
        return
        ;;
    esac
    # .../releases/latest redirects to .../releases/tag/vX.Y.Z
    tag=$(curl -fsLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
    tag=${tag##*/}
    case $tag in
    v[0-9]*) ;;
    *) tag=$(gh release view -R "$REPO" --json tagName --jq .tagName </dev/null 2>/dev/null || true) ;;
    esac
    case $tag in
    v[0-9]*) echo "$tag" ;;
    *) fail "could not find the latest release of $REPO $hint" ;;
    esac
}

# Downloads file $2 of release $1 into $TMP: anonymously, or through the
# GitHub CLI when the repository is private.
fetch() {
    url=https://github.com/$REPO/releases/download/$1/$2
    curl -fsL --retry 2 -o "$TMP/$2" "$url" && return 0
    command -v gh >/dev/null 2>&1 &&
        gh release download "$1" -R "$REPO" -p "$2" -D "$TMP" --clobber </dev/null >/dev/null 2>&1 &&
        return 0
    fail "could not download $url $hint"
}

uninstall_ufits() {
    stop
    launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
    gone=0
    for dir in ${UFITS_DEST:+"$UFITS_DEST"} /Applications "$HOME/Applications"; do
        [ -d "$dir/$APP" ] || continue
        unregister "$dir/$APP"
        rm -rf "$dir/$APP" || fail "could not remove $dir/$APP"
        say "Removed $dir/$APP"
        gone=1
    done
    reset_quicklook
    [ $gone = 1 ] || say "uFits is not installed."
}

install_ufits() {
    if [ -n "${UFITS_DEST:-}" ]; then
        dest=$UFITS_DEST
    elif [ -w /Applications ]; then
        dest=/Applications
    else
        dest=$HOME/Applications
    fi

    TMP=$(mktemp -d "${TMPDIR:-/tmp}/ufits.XXXXXX")
    MNT=$TMP/mnt
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM

    if [ -n "${UFITS_DMG:-}" ]; then
        dmg=$UFITS_DMG
        [ -f "$dmg" ] || fail "no disk image $dmg"
    else
        tag=$(release_tag) || exit 1
        dmg=uFits-${tag#v}.dmg
        say "Downloading uFits ${tag#v}..."
        fetch "$tag" "$dmg"
        fetch "$tag" "$dmg.sha256"
        want=$(awk '{ print $1; exit }' "$TMP/$dmg.sha256")
        got=$(shasum -a 256 "$TMP/$dmg" | awk '{ print $1 }')
        [ -n "$want" ] && [ "$want" = "$got" ] || fail "the download is damaged (its SHA-256 does not match)"
        dmg=$TMP/$dmg
    fi

    mkdir -p "$MNT"
    hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint "$MNT" "$dmg" </dev/null ||
        fail "could not open $dmg"
    mounted=1
    [ -d "$MNT/$APP" ] || fail "$dmg holds no $APP"

    stop
    mkdir -p "$dest" || fail "could not make $dest"
    unregister "$dest/$APP"
    rm -rf "$dest/$APP" || fail "could not replace $dest/$APP"
    ditto "$MNT/$APP" "$dest/$APP" || fail "could not copy uFits to $dest"
    hdiutil detach -quiet "$MNT" 2>/dev/null && mounted=0
    xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

    # Register the app and turn its Quick Look extensions on.
    "$LSREGISTER" -f -R -trusted "$dest/$APP" 2>/dev/null || true
    for ext in "$dest/$APP"/Contents/PlugIns/*.appex; do
        pluginkit -a "$ext" 2>/dev/null || true
    done
    for id in $IDS; do
        pluginkit -e use -i "$id" 2>/dev/null || true
    done
    reset_quicklook
    # Looking for updates now and then, unless turned off in the app.
    "$dest/$APP/Contents/MacOS/uFits" --schedule-update-checks >/dev/null 2>&1 || true

    for id in $IDS; do
        pluginkit -m -i "$id" 2>/dev/null | grep -q "$id" ||
            say "Note: Quick Look has not picked up $id yet; opening uFits from $dest once registers it."
    done
    version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || true)
    say "uFits $version is installed in $dest. Select a FITS file in Finder and press Space."
}

# Runs once sh has read the whole script: piped into sh, a command reading
# stdin would otherwise eat the rest of it.
main() {
    [ "$(uname -s)" = Darwin ] || fail "uFits is a macOS app."
    [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 11 ] || fail "uFits needs macOS 11 or later."
    # Quick Look extensions are registered for the user who runs this.
    [ "$(id -u)" != 0 ] || fail "run this without sudo, as the user who will use uFits."
    case ${1:-} in
    "") install_ufits ;;
    --uninstall) uninstall_ufits ;;
    *) fail "unknown option $1 (the only one is --uninstall)" ;;
    esac
}

main "$@"
