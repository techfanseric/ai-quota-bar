.PHONY: build run install clean

BUILD_DIR = .build
PRODUCT = MiniMaxUsageMonitor.app

build:
	swift build -c release --product MiniMaxUsageMonitor

run: build
	open $(BUILD_DIR)/release/$(PRODUCT)

install: build
	cp -R $(BUILD_DIR)/release/$(PRODUCT) /Applications/

clean:
	swift package reset
	rm -rf $(BUILD_DIR)
