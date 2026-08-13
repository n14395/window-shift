APP_NAME = WindowShift
BUNDLE_ID = dev.nwf.WindowShift
BUILD_DIR = .build/release
APP = dist/$(APP_NAME).app

all: app

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

run: app
	open $(APP)

clean:
	rm -rf .build dist

.PHONY: all build app run clean
