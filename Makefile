.PHONY: build run app sign install package clean

BUILD_DIR = .build
PRODUCT = MiniMaxUsageMonitor.app
APP_NAME = MiniMaxUsageMonitor
APP_BUNDLE_ID = com.minimax.usagemonitor
APP_VERSION ?= 1.1.0
APP_BUILD ?= 2
CODESIGN_IDENTITY ?= -

build:
	swift build -c release --product $(APP_NAME)

app: build
	@mkdir -p dist/$(PRODUCT)/Contents/{MacOS,Resources}
	@cp .build/release/$(APP_NAME) dist/$(PRODUCT)/Contents/MacOS/
	@rm -rf dist/AppIcon.iconset
	@mkdir -p dist/AppIcon.iconset
	@for f in MiniMaxUsageMonitor/Resources/Assets.xcassets/AppIcon.appiconset/*.png; do \
		sips -s format png "$$f" --out "dist/AppIcon.iconset/$$(basename "$$f")" >/dev/null; \
	done
	@iconutil -c icns dist/AppIcon.iconset -o dist/$(PRODUCT)/Contents/Resources/AppIcon.icns
	@rm -rf dist/AppIcon.iconset
	@echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundleIdentifier</key><string>$(APP_BUNDLE_ID)</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleName</key><string>$(APP_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$(APP_VERSION)</string><key>CFBundleVersion</key><string>$(APP_BUILD)</string><key>CFBundleIconFile</key><string>AppIcon</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>' > dist/$(PRODUCT)/Contents/Info.plist
	@chmod +x dist/$(PRODUCT)/Contents/MacOS/$(APP_NAME)

sign: app
	@echo "Signing app with identity: $(CODESIGN_IDENTITY)"
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		codesign --force --deep --sign - dist/$(PRODUCT); \
	else \
		codesign --force --deep --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" dist/$(PRODUCT); \
	fi
	@codesign --verify --deep --strict --verbose=2 dist/$(PRODUCT)

run: build
	open $(BUILD_DIR)/release/$(APP_NAME)

install: sign
	cp -R dist/$(PRODUCT) /Applications/

package: sign
	@rm -rf dist/dmg-root
	@mkdir -p dist/dmg-root
	@cp -R dist/$(PRODUCT) dist/dmg-root/$(PRODUCT)
	@ln -s /Applications dist/dmg-root/Applications
	@hdiutil create dist/$(APP_NAME).dmg -volname "$(APP_NAME)" -fs APFS -srcfolder dist/dmg-root -ov -format UDZO
	@rm -rf dist/dmg-root

clean:
	swift package reset
	rm -rf $(BUILD_DIR) dist
