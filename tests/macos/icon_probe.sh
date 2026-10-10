#!/bin/bash
# Probe (temporary): which icon macOS draws when the flattened images of the
# icon for macOS 26 are removed from Assets.car, or become Dusk's.
# Usage: tests/macos/icon_probe.sh (after make app).
set -u
X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
export DEVELOPER_DIR=$X/Contents/Developer
echo "Xcode: $X"
W=/tmp/iv
rm -rf $W
mkdir -p $W/apps $W/src
xcrun clang -fobjc-arc -framework Foundation tests/macos/caricon.m -o $W/caricon || exit 1

summary() {
  xcrun assetutil --info "$1" 2>/dev/null | python3 -c '
import collections, json, sys
icons = collections.defaultdict(list)
for r in json.load(sys.stdin)[1:]:
    icons[r.get("Name"), r.get("AssetType"), r.get("Appearance", "any")].append(str(r.get("PixelWidth", "-")))
for (name, kind, look), px in icons.items():
    if not name.startswith(("AppIcon_Assets", "ZZZZ")):
        print("    ", name, "|", kind, "|", look, "|", " ".join(px))'
}
mkapp() {  # app car-directory
  app=$W/apps/$1.app
  mkdir -p $app/Contents/MacOS $app/Contents/Resources
  cp macos/App/AppIcon.icns $app/Contents/Resources/AppIcon.icns
  cp $W/$2/Assets.car $app/Contents/Resources/Assets.car
  cat > $app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.lmytime.probe.$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
</dict></plist>
EOF
  printf '#!/bin/sh\n' > $app/Contents/MacOS/probe
  chmod +x $app/Contents/MacOS/probe
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $app
}
compile() {  # directory actool-arguments...
  d=$W/$1
  shift
  mkdir -p $d
  xcrun actool "$@" --compile $d --platform macosx --output-partial-info-plist $d/partial.plist \
    --minimum-deployment-target 11.0 --warnings --notices --errors 2>&1 | grep -E 'error|warning'
}

mkdir -p $W/src/Dusk.xcassets
cp macos/App/Assets.xcassets/Contents.json $W/src/Dusk.xcassets/
cp -R macos/App/Assets.xcassets/AppIcon.appiconset $W/src/Dusk.xcassets/AppIconDusk.appiconset

compile plain macos/App/AppIcon.icon --app-icon AppIcon
compile both macos/App/AppIcon.icon $W/src/Dusk.xcassets --app-icon AppIcon --include-all-app-icons
echo "== plain, as actool makes it"
$W/caricon dump $W/plain/Assets.car
echo "== both, as actool makes it"
$W/caricon dump $W/both/Assets.car

mkdir -p $W/strip $W/swap
cp $W/plain/Assets.car $W/strip/
cp $W/both/Assets.car $W/swap/
echo "== strip"
$W/caricon strip $W/strip/Assets.car AppIcon && $W/caricon dump $W/strip/Assets.car && summary $W/strip/Assets.car
echo "== swap"
$W/caricon swap $W/swap/Assets.car AppIcon AppIconDusk && $W/caricon dump $W/swap/Assets.car && summary $W/swap/Assets.car

for v in plain both strip swap; do mkapp $v $v; done
make build/iconsize >/dev/null
echo "== the icons drawn (mean r g b; Dusk is dark)"
build/iconsize $W/icons.png $W/apps/*.app
case $(sw_vers -productVersion) in
1[0-9].*) ;;
*)
  defaults write -g AppleIconAppearanceTheme -string RegularDark
  killall Dock || true
  sleep 6
  echo "== with dark icons"
  build/iconsize $W/icons-dark.png $W/apps/*.app
  defaults delete -g AppleIconAppearanceTheme || true
  killall Dock || true
  ;;
esac
exit 0
