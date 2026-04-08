.PHONY: build run install package clean

BUILD_DIR = .build
PRODUCT = MiniMaxUsageMonitor.app

build:
	swift build -c release --product MiniMaxUsageMonitor

run: build
	open $(BUILD_DIR)/release/$(PRODUCT)

install: build
	cp -R $(BUILD_DIR)/release/$(PRODUCT) /Applications/

package: build
	@mkdir -p dist/MiniMaxUsageMonitor.app/Contents/{MacOS,Resources}
	@cp .build/release/MiniMaxUsageMonitor dist/MiniMaxUsageMonitor.app/Contents/MacOS/
	@cp -R MiniMaxUsageMonitor/Resources/Assets.xcassets dist/MiniMaxUsageMonitor.app/Contents/Resources/
	@echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MiniMaxUsageMonitor</string><key>CFBundleIdentifier</key><string>com.minimax.usagemonitor</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleName</key><string>MiniMaxUsageMonitor</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>' > dist/MiniMaxUsageMonitor.app/Contents/Info.plist
	@chmod +x dist/MiniMaxUsageMonitor.app/Contents/MacOS/MiniMaxUsageMonitor
	@hdiutil create dist/MiniMaxUsageMonitor.dmg -volname "MiniMaxUsageMonitor" -fs APFS -srcfolder dist/MiniMaxUsageMonitor.app -ov -format UDZO
	@rm -rf dist/MiniMaxUsageMonitor.app

clean:
	swift package reset
	rm -rf $(BUILD_DIR) dist
