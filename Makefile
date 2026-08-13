APP_NAME = WindowShift
BUNDLE_ID = dev.nwf.WindowShift
BUILD_DIR = .build/release
APP = dist/$(APP_NAME).app
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.0.0)
DMG = dist/$(APP_NAME)-$(VERSION).dmg

all: app dmg

build:
	swift build -c release

# Sign with a stable identity so the Accessibility (TCC) grant survives
# rebuilds: $CODESIGN_IDENTITY, else the first Apple Development cert, else
# ad-hoc with a pinned identifier-based designated requirement.
IDENTITY := $(or $(CODESIGN_IDENTITY),$(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}'))

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(BUILD_DIR)/$(APP_NAME) $(APP)/Contents/MacOS/$(APP_NAME)
ifneq ($(IDENTITY),)
	codesign --force --sign $(IDENTITY) --identifier $(BUNDLE_ID) $(APP)
else
	codesign --force --sign - --identifier $(BUNDLE_ID) \
		--requirements '=designated => identifier "$(BUNDLE_ID)"' $(APP)
endif
	@echo "Built $(APP) (signed: $(or $(IDENTITY),ad-hoc+pinned-requirement))"

# Distributable disk image: the app plus an /Applications symlink for
# drag-install, compressed (UDZO). Rebuilt on every build.
dmg: app
	rm -f dist/$(APP_NAME)-*.dmg
	STAGING=$$(mktemp -d) && \
	cp -R $(APP) $$STAGING/ && \
	ln -s /Applications $$STAGING/Applications && \
	hdiutil create -quiet -volname $(APP_NAME) -srcfolder $$STAGING -ov -format UDZO $(DMG) && \
	rm -rf $$STAGING
	@echo "Built $(DMG)"

run: all
	open $(APP)

clean:
	rm -rf .build dist

.PHONY: all build app dmg run clean
