#!/bin/bash
# Probe (temporary): which icon macOS draws for each way of compiling the
# app's icon with actool. Usage: tests/macos/icon_probe.sh (after make app).
set -u
X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
export DEVELOPER_DIR=$X/Contents/Developer
echo "Xcode: $X"
xcrun actool --version | grep -A1 bundle-version | tail -1
xcrun actool --help 2>&1 | grep -E '^\s*--' | sort -u

echo "== strings about fallbacks and appearances"
for f in $(find "$X/Contents" -maxdepth 8 -type f \( -name AssetCatalogFoundation -o -name actool \
    -o -name 'IconComposer*' -o -name 'IconRendering*' -o -name 'CoreThemeDefinition' \) 2>/dev/null | head -12); do
  echo "-- $f"
  strings -a "$f" | grep -E -i 'fallback|flatten|icon.?stack|specializ|appearance|legacy' | sort -u | head -60
done

W=/tmp/iv
rm -rf $W
mkdir -p $W/apps $W/src
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
mkapp() {  # name [icon name]
  app=$W/apps/$1.app
  mkdir -p $app/Contents/MacOS $app/Contents/Resources
  cp macos/App/AppIcon.icns $app/Contents/Resources/AppIcon.icns
  [ -f $W/$1/Assets.car ] && cp $W/$1/Assets.car $app/Contents/Resources/Assets.car
  cat > $app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.lmytime.probe.$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>${2:-AppIcon}</string>
</dict></plist>
EOF
  printf '#!/bin/sh\n' > $app/Contents/MacOS/probe
  chmod +x $app/Contents/MacOS/probe
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $app
}
variant() {  # name actool-arguments...
  name=$1
  shift
  mkdir -p $W/$name
  echo "== $name: actool $*"
  xcrun actool "$@" --compile $W/$name --platform macosx --output-partial-info-plist $W/$name/partial.plist \
    --warnings --notices --errors 2>&1 | grep -v -E '^dyld|^<|^\s*<|^\s*$'
  plutil -p $W/$name/partial.plist 2>/dev/null | grep -v -E '^\{|^\}'
  echo "   files: $(ls $W/$name | tr '\n' ' ')"
  [ -f $W/$name/Assets.car ] && summary $W/$name/Assets.car
  mkapp $name
}

# The icon, its light layer shown only for a "light" appearance, if there is one.
cp -R macos/App/AppIcon.icon $W/src/LightSpec.icon
python3 - $W/src/LightSpec.icon/icon.json <<'EOF'
import json, sys
p = sys.argv[1]
icon = json.load(open(p))
light = icon["groups"][0]["layers"][0]
light["hidden"] = True
light["hidden-specializations"] = [{"appearance": "light", "value": False}]
json.dump(icon, open(p, "w"), indent=2)
EOF
mkdir -p $W/src/LightSpec
cp -R $W/src/LightSpec.icon $W/src/LightSpec/AppIcon.icon

variant icon11 macos/App/AppIcon.icon --app-icon AppIcon --minimum-deployment-target 11.0
variant icon26 macos/App/AppIcon.icon --app-icon AppIcon --minimum-deployment-target 26.0
variant noappicon macos/App/AppIcon.icon --minimum-deployment-target 26.0
variant standalone macos/App/AppIcon.icon --app-icon AppIcon --minimum-deployment-target 26.0 \
  --standalone-icon-behavior none
variant both26 macos/App/AppIcon.icon macos/App/Assets.xcassets --app-icon AppIcon --minimum-deployment-target 26.0
variant catalog macos/App/Assets.xcassets --app-icon AppIcon --minimum-deployment-target 11.0
variant lightspec $W/src/LightSpec/AppIcon.icon --app-icon AppIcon --minimum-deployment-target 11.0
mkapp icns-only NoSuchIcon

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
