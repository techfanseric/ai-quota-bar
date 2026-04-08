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
	@mkdir -p dist
	@hdiutil create dist/MiniMaxUsageMonitor.dmg -volname "MiniMaxUsageMonitor" -fs APFS -srcfolder "$(BUILD_DIR)/release/MiniMaxUsageMonitor.app" -ov -format UDZO

clean:
	swift package reset
	rm -rf $(BUILD_DIR)
