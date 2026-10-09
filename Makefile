# uFits - Quick Look previews and thumbnails for FITS files.
#
# Builds with the Xcode command line tools alone (no Xcode project):
#
#   make            build/uFits.app (universal, ad hoc signed)
#   make install    copy it to /Applications and register the extensions
#   make zip        build/uFits.zip, ready to share
#   make test       check the core against astropy (needs python3 with
#                   numpy and astropy; also works on Linux)
#
# Options:
#   SIGN="Developer ID Application: Name (TEAMID)"   sign for distribution
#   ARCHS=arm64                                      native-only build
#   GZIP=1             also preview .gz files (claims every gzip file)
#   BUNDLE_ID=...      change the bundle identifier prefix
#
# Works with the GNU make 3.81 that ships with macOS.

APP        := uFits
BUNDLE_ID  ?= io.github.lmytime.uFits
VERSION    ?= 1.0.0
BUILD_NUM  ?= 1
MINOS      ?= 11.0
ARCHS      ?= arm64 x86_64
SIGN       ?= -
GZIP       ?= 0
DEST       ?= /Applications
B          ?= build

CC      := clang
HOSTCC  ?= cc
ARCHF   := $(foreach a,$(ARCHS),-arch $(a))
WARN    := -Wall -Wextra -Wno-unused-parameter
COMMON  := $(ARCHF) -mmacosx-version-min=$(MINOS) -O2 $(WARN) -Icore -Imacos/Shared
CFLAGS_ := -std=c11 $(COMMON)
OBJC_   := -fobjc-arc -fmodules $(COMMON)
EXT     := -fapplication-extension
LDF     := $(ARCHF) -mmacosx-version-min=$(MINOS) -fobjc-arc

APPDIR  := $(B)/$(APP).app
PLUGINS := $(APPDIR)/Contents/PlugIns
PREVIEW := $(PLUGINS)/uFitsPreview.appex
THUMB   := $(PLUGINS)/uFitsThumbnail.appex
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

ifeq ($(GZIP),1)
EXTRA_TYPES := <string>org.gnu.gnu-zip-archive</string>
else
EXTRA_TYPES :=
endif

ifeq ($(SIGN),-)
SIGNFLAGS :=
else
SIGNFLAGS := --options runtime --timestamp
endif

CORE_H   := core/fq.h core/fq_internal.h
CORE_SRC := core/fq.c core/fq_image.c core/fq_table.c core/fq_codec.c
CORE_OBJ := $(patsubst core/%.c,$(B)/obj/core/%.o,$(CORE_SRC))
SHARED_H := macos/Shared/FQRender.h macos/Shared/FQPreviewController.h

APP_OBJ     := $(B)/obj/app/main.o $(B)/obj/app/FQRender.o $(B)/obj/app/FQPreviewController.o
PREVIEW_OBJ := $(B)/obj/ext/PreviewViewController.o $(B)/obj/ext/FQRender.o $(B)/obj/ext/FQPreviewController.o
THUMB_OBJ   := $(B)/obj/ext/ThumbnailProvider.o $(B)/obj/ext/FQRender.o

.PHONY: all app install uninstall zip test fqtool qltools clean

all: app

app: $(APPDIR)/Contents/_CodeSignature/CodeResources

# --- objects ---------------------------------------------------------------

$(B)/obj/core/%.o: core/%.c $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_) -c $< -o $@

$(B)/obj/app/%.o: macos/App/%.m $(SHARED_H) $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(OBJC_) -c $< -o $@

$(B)/obj/app/%.o: macos/Shared/%.m $(SHARED_H) $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(OBJC_) -c $< -o $@

$(B)/obj/ext/%.o: macos/Shared/%.m $(SHARED_H) $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(OBJC_) $(EXT) -c $< -o $@

$(B)/obj/ext/%.o: macos/Preview/%.m $(SHARED_H) $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(OBJC_) $(EXT) -c $< -o $@

$(B)/obj/ext/%.o: macos/Thumbnail/%.m $(SHARED_H) $(CORE_H)
	@mkdir -p $(dir $@)
	$(CC) $(OBJC_) $(EXT) -c $< -o $@

# --- executables -----------------------------------------------------------

$(APPDIR)/Contents/MacOS/$(APP): $(APP_OBJ) $(CORE_OBJ)
	@mkdir -p $(dir $@)
	$(CC) $(LDF) -o $@ $^ -framework Cocoa -framework QuartzCore -framework UniformTypeIdentifiers -lz

$(PREVIEW)/Contents/MacOS/uFitsPreview: $(PREVIEW_OBJ) $(CORE_OBJ)
	@mkdir -p $(dir $@)
	$(CC) $(LDF) $(EXT) -Wl,-e,_NSExtensionMain -o $@ $^ -framework Cocoa -framework Quartz -framework QuartzCore -lz

$(THUMB)/Contents/MacOS/uFitsThumbnail: $(THUMB_OBJ) $(CORE_OBJ)
	@mkdir -p $(dir $@)
	$(CC) $(LDF) $(EXT) -Wl,-e,_NSExtensionMain -o $@ $^ -framework Foundation -framework CoreGraphics -framework QuickLookThumbnailing -lz

# --- bundle metadata -------------------------------------------------------

define make_plist
	@mkdir -p $(dir $(2))
	sed -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
	    -e 's/@BUILD@/$(BUILD_NUM)/g' -e 's/@MINOS@/$(MINOS)/g' \
	    -e 's|<!--@EXTRA_TYPES@-->|$(EXTRA_TYPES)|g' $(1) > $(2)
	plutil -lint -s $(2)
endef

$(APPDIR)/Contents/Info.plist: macos/App/Info.plist Makefile
	$(call make_plist,$<,$@)

$(PREVIEW)/Contents/Info.plist: macos/Preview/Info.plist Makefile
	$(call make_plist,$<,$@)

$(THUMB)/Contents/Info.plist: macos/Thumbnail/Info.plist Makefile
	$(call make_plist,$<,$@)

$(APPDIR)/Contents/Resources/AppIcon.icns: macos/App/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

# --- signing ---------------------------------------------------------------
# Extensions must be signed (sandboxed) before the app that contains them.

BUNDLE_PARTS := $(APPDIR)/Contents/MacOS/$(APP) $(APPDIR)/Contents/Info.plist \
	$(APPDIR)/Contents/Resources/AppIcon.icns \
	$(PREVIEW)/Contents/MacOS/uFitsPreview $(PREVIEW)/Contents/Info.plist \
	$(THUMB)/Contents/MacOS/uFitsThumbnail $(THUMB)/Contents/Info.plist

$(APPDIR)/Contents/_CodeSignature/CodeResources: $(BUNDLE_PARTS) macos/Preview/Preview.entitlements macos/Thumbnail/Thumbnail.entitlements
	printf 'APPL????' > $(APPDIR)/Contents/PkgInfo
	codesign --force --sign "$(SIGN)" $(SIGNFLAGS) --entitlements macos/Preview/Preview.entitlements $(PREVIEW)
	codesign --force --sign "$(SIGN)" $(SIGNFLAGS) --entitlements macos/Thumbnail/Thumbnail.entitlements $(THUMB)
	codesign --force --sign "$(SIGN)" $(SIGNFLAGS) $(APPDIR)
	codesign --verify --deep --strict $(APPDIR)
	@echo "Built $(APPDIR)"

# --- install ---------------------------------------------------------------

install: app
	-pluginkit -r $(PREVIEW) 2>/dev/null
	-pluginkit -r $(THUMB) 2>/dev/null
	-$(LSREGISTER) -u $(APPDIR) 2>/dev/null
	rm -rf "$(DEST)/$(APP).app"
	ditto $(APPDIR) "$(DEST)/$(APP).app"
	$(LSREGISTER) -f -R -trusted "$(DEST)/$(APP).app"
	pluginkit -a "$(DEST)/$(APP).app/Contents/PlugIns/uFitsPreview.appex"
	pluginkit -a "$(DEST)/$(APP).app/Contents/PlugIns/uFitsThumbnail.appex"
	qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1; true
	@echo "Installed $(DEST)/$(APP).app - select a FITS file in Finder and press Space."

uninstall:
	-pluginkit -r "$(DEST)/$(APP).app/Contents/PlugIns/uFitsPreview.appex"
	-pluginkit -r "$(DEST)/$(APP).app/Contents/PlugIns/uFitsThumbnail.appex"
	-$(LSREGISTER) -u "$(DEST)/$(APP).app"
	rm -rf "$(DEST)/$(APP).app"
	qlmanage -r >/dev/null 2>&1; qlmanage -r cache >/dev/null 2>&1; true

zip: app
	rm -f $(B)/$(APP).zip
	ditto -c -k --keepParent $(APPDIR) $(B)/$(APP).zip
	@echo "Wrote $(B)/$(APP).zip"

# --- core tests (portable) ---------------------------------------------------

fqtool: $(B)/fqtool

$(B)/fqtool: tools/fqtool.c $(CORE_SRC) $(CORE_H)
	@mkdir -p $(B)
	$(HOSTCC) -std=c99 -O2 $(WARN) -Icore -o $@ tools/fqtool.c $(CORE_SRC) -lz -lm -lpthread

test: $(B)/fqtool
	python3 tests/make_test_files.py $(B)/testdata
	python3 tests/test_core.py $(B)/fqtool $(B)/testdata

# Checks used by CI: thumbnails through QLThumbnailGenerator and previews
# through QLPreviewView, both served by the installed extensions, and the
# preview UI driven directly (HDU menu, plane slider, find bar).
qltools: $(B)/qlthumb $(B)/qlpreview $(B)/uitest

$(B)/qlthumb: tests/macos/qlthumb.m
	@mkdir -p $(B)
	$(CC) -fobjc-arc -fmodules -O2 -o $@ $< -framework Foundation -framework QuickLookThumbnailing \
	    -framework ImageIO -framework UniformTypeIdentifiers

$(B)/qlpreview: tests/macos/qlpreview.m
	@mkdir -p $(B)
	$(CC) -fobjc-arc -fmodules -O2 -o $@ $< -framework Cocoa -framework Quartz

$(B)/uitest: tests/macos/uitest.m $(B)/obj/app/FQPreviewController.o $(B)/obj/app/FQRender.o $(CORE_OBJ)
	@mkdir -p $(B)
	$(CC) $(OBJC_) -o $@ $^ -framework Cocoa -framework QuartzCore -lz

clean:
	rm -rf $(B)
