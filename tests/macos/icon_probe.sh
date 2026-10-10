#!/bin/bash
# Probe (temporary): which icon macOS draws for each way of compiling the
# app's icon with actool. Usage: tests/macos/icon_probe.sh (after make app).
set -u
X=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
export DEVELOPER_DIR=$X/Contents/Developer
echo "Xcode: $X"

echo "== actool's options"
xcrun actool --help 2>&1 | head -5
xcrun actool 2>&1 | head -5
timeout 150 grep -rl -a 'standalone-icon-behavior' "$X/Contents/Developer/usr" "$X/Contents/Frameworks" \
  "$X/Contents/SharedFrameworks" "$X/Contents/PlugIns" 2>/dev/null | head -5 | while IFS= read -r f; do
  echo "-- $f"
  strings -a "$f" | grep -E '^[a-z][a-z0-9]*(-[a-z0-9]+)+$' | sort -u | tr '\n' ' '
  echo
done
echo "== Info.plist keys for icons, in the system's frameworks"
LC_ALL=C timeout 120 grep -a -o -h -E '(CFBundle[A-Za-z]*Icon[A-Za-z~]*|CFBundlePrimaryIcon)' \
  /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e* 2>/dev/null | sort | uniq -c | sort -rn | head -40
echo

echo "== CoreUI's asset storage"
cat > /tmp/cui.m <<'EOF'
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
int main(int argc, char **argv) {
    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
    for (int i = 1; i < argc; i++) {
        Class c = objc_getClass(argv[i]);
        printf("%s : %s\n", argv[i], c ? class_getName(class_getSuperclass(c)) : "(none)");
        unsigned n = 0;
        Method *m = class_copyMethodList(c, &n);
        for (unsigned k = 0; k < n; k++)
            printf("  - %s %s\n", sel_getName(method_getName(m[k])), method_getTypeEncoding(m[k]));
        free(m);
    }
    return 0;
}
EOF
xcrun clang -fobjc-arc -framework Foundation /tmp/cui.m -o /tmp/cui && /tmp/cui CUICommonAssetStorage CUIMutableCommonAssetStorage

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
mkapp() {  # app car icon-name [primary icon name, in CFBundleIcons]
  app=$W/apps/$1.app
  mkdir -p $app/Contents/MacOS $app/Contents/Resources
  cp macos/App/AppIcon.icns $app/Contents/Resources/AppIcon.icns
  cp $W/$2/Assets.car $app/Contents/Resources/Assets.car
  icons=
  [ -n "${4:-}" ] && icons="<key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>$4</string></dict></dict>"
  cat > $app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.lmytime.probe.$1</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>$3</string>
$icons
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
}

# The catalog's Dusk, named AppIconDusk.
mkdir -p $W/src/Dusk.xcassets
cp macos/App/Assets.xcassets/Contents.json $W/src/Dusk.xcassets/
cp -R macos/App/Assets.xcassets/AppIcon.appiconset $W/src/Dusk.xcassets/AppIconDusk.appiconset

variant all macos/App/AppIcon.icon $W/src/Dusk.xcassets --app-icon AppIcon --include-all-app-icons \
  --minimum-deployment-target 11.0
variant alt macos/App/AppIcon.icon $W/src/Dusk.xcassets --app-icon AppIcon --alternate-app-icon AppIconDusk \
  --minimum-deployment-target 11.0
variant duskprimary macos/App/AppIcon.icon $W/src/Dusk.xcassets --app-icon AppIconDusk --alternate-app-icon AppIcon \
  --minimum-deployment-target 11.0
for v in all alt duskprimary; do
  [ -f $W/$v/Assets.car ] || continue
  mkapp $v-name-dusk-icons-icon $v AppIconDusk AppIcon
  mkapp $v-name-icon-icons-dusk $v AppIcon AppIconDusk
  mkapp $v-name-dusk $v AppIconDusk
  mkapp $v-name-icon $v AppIcon
done

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
