.PHONY: build run app sign stable-sign install stable-install package clean

BUILD_DIR = .build
PRODUCT = AIQuotaBar.app
APP_NAME = AIQuotaBar
APP_DISPLAY_NAME = AI Quota Bar
APP_BUNDLE_ID = com.techfanseric.aiquotabar
SLEEP_HELPER_BUNDLE_ID = com.techfanseric.aiquotabar.sleep-helper
APP_VERSION ?= 1.11.0
APP_BUILD ?= 26
CODESIGN_IDENTITY ?= -
EXPECTED_TEAM_ID ?=
STABLE_CODESIGN_IDENTITY ?=
STABLE_TEAM_ID ?=

build:
	swift build -c release --product $(APP_NAME)
	swift build -c release --product AIQuotaBarHook
	swift build -c release --product AIQuotaBarSleepHelper

app: build
	@mkdir -p dist/$(PRODUCT)/Contents/{MacOS,Resources,Helpers,Library/LaunchDaemons}
	@cp .build/release/$(APP_NAME) dist/$(PRODUCT)/Contents/MacOS/
	@cp .build/release/AIQuotaBarHook dist/$(PRODUCT)/Contents/Helpers/
	@cp .build/release/AIQuotaBarSleepHelper dist/$(PRODUCT)/Contents/MacOS/
	@if [ -d .build/release/$(APP_NAME)_$(APP_NAME).bundle ]; then \
		cp -R .build/release/$(APP_NAME)_$(APP_NAME).bundle dist/$(PRODUCT)/Contents/Resources/; \
	fi
	@rm -rf dist/AppIcon.iconset
	@mkdir -p dist/AppIcon.iconset
	@for f in AIQuotaBar/Resources/Assets.xcassets/AppIcon.appiconset/*.png; do \
		sips -s format png "$$f" --out "dist/AppIcon.iconset/$$(basename "$$f")" >/dev/null; \
	done
	@iconutil -c icns dist/AppIcon.iconset -o dist/$(PRODUCT)/Contents/Resources/AppIcon.icns
	@rm -rf dist/AppIcon.iconset
	@echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>$(APP_NAME)</string><key>CFBundleIdentifier</key><string>$(APP_BUNDLE_ID)</string><key>CFBundleInfoDictionaryVersion</key><string>6.0</string><key>CFBundleName</key><string>$(APP_NAME)</string><key>CFBundleDisplayName</key><string>$(APP_DISPLAY_NAME)</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$(APP_VERSION)</string><key>CFBundleVersion</key><string>$(APP_BUILD)</string><key>CFBundleIconFile</key><string>AppIcon</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/><key>NSLocalNetworkUsageDescription</key><string>AI Quota Bar uses your local network only while Mobile Dashboard is enabled, so nearby devices can view read-only quota and status information.</string></dict></plist>' > dist/$(PRODUCT)/Contents/Info.plist
	@echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$(SLEEP_HELPER_BUNDLE_ID)</string><key>BundleProgram</key><string>Contents/MacOS/AIQuotaBarSleepHelper</string><key>AssociatedBundleIdentifiers</key><array><string>$(APP_BUNDLE_ID)</string></array><key>MachServices</key><dict><key>$(SLEEP_HELPER_BUNDLE_ID)</key><true/></dict><key>ProcessType</key><string>Background</string></dict></plist>' > dist/$(PRODUCT)/Contents/Library/LaunchDaemons/$(SLEEP_HELPER_BUNDLE_ID).plist
	@echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$(SLEEP_HELPER_BUNDLE_ID)</string><key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/$(SLEEP_HELPER_BUNDLE_ID)</string></array><key>MachServices</key><dict><key>$(SLEEP_HELPER_BUNDLE_ID)</key><true/></dict><key>ProcessType</key><string>Background</string></dict></plist>' > dist/$(PRODUCT)/Contents/Resources/$(SLEEP_HELPER_BUNDLE_ID).legacy.plist
	@chmod +x dist/$(PRODUCT)/Contents/MacOS/$(APP_NAME)
	@chmod +x dist/$(PRODUCT)/Contents/MacOS/AIQuotaBarSleepHelper
	@chmod +x dist/$(PRODUCT)/Contents/Helpers/AIQuotaBarHook

sign: app
	@echo "Signing app with identity: $(CODESIGN_IDENTITY)"
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
		echo "Using the one-time administrator-installed helper flow for ad-hoc builds."; \
		codesign --force --options runtime --identifier "$(SLEEP_HELPER_BUNDLE_ID)" --sign - dist/$(PRODUCT)/Contents/MacOS/AIQuotaBarSleepHelper; \
		codesign --force --options runtime --sign - dist/$(PRODUCT)/Contents/Helpers/AIQuotaBarHook; \
		codesign --force --options runtime --sign - dist/$(PRODUCT); \
	else \
		codesign --force --options runtime --timestamp --identifier "$(SLEEP_HELPER_BUNDLE_ID)" --sign "$(CODESIGN_IDENTITY)" dist/$(PRODUCT)/Contents/MacOS/AIQuotaBarSleepHelper; \
		codesign --force --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" dist/$(PRODUCT)/Contents/Helpers/AIQuotaBarHook; \
		codesign --force --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" dist/$(PRODUCT); \
	fi
	@codesign --verify --deep --strict --verbose=2 dist/$(PRODUCT)
	@if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		if [ -z "$(EXPECTED_TEAM_ID)" ]; then \
			echo "EXPECTED_TEAM_ID is required for non-ad-hoc signing." >&2; \
			exit 1; \
		fi; \
		for component in \
			dist/$(PRODUCT) \
			dist/$(PRODUCT)/Contents/MacOS/AIQuotaBarSleepHelper \
			dist/$(PRODUCT)/Contents/Helpers/AIQuotaBarHook; do \
			team=$$(codesign -dv --verbose=4 "$$component" 2>&1 \
				| sed -n 's/^TeamIdentifier=//p'); \
			if [ "$$team" != "$(EXPECTED_TEAM_ID)" ]; then \
				echo "Unexpected TeamIdentifier for $$component: $$team" >&2; \
				exit 1; \
			fi; \
		done; \
	fi

stable-sign:
	@if [ -z "$(STABLE_CODESIGN_IDENTITY)" ] \
		|| [ -z "$(STABLE_TEAM_ID)" ]; then \
		echo "Pass STABLE_CODESIGN_IDENTITY and STABLE_TEAM_ID explicitly." >&2; \
		exit 1; \
	fi
	@$(MAKE) sign \
		CODESIGN_IDENTITY="$(STABLE_CODESIGN_IDENTITY)" \
		EXPECTED_TEAM_ID="$(STABLE_TEAM_ID)"

run: build
	open $(BUILD_DIR)/release/$(APP_NAME)

install: sign
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@while pgrep -x $(APP_NAME) >/dev/null 2>&1; do sleep 0.1; done
	@install_dir=$$(mktemp -d /tmp/aiquotabar-install.XXXXXX); \
		if [ -d /Applications/$(PRODUCT) ]; then \
			mv /Applications/$(PRODUCT) "$$install_dir/$(PRODUCT).previous"; \
		fi; \
		if cp -R dist/$(PRODUCT) /Applications/$(PRODUCT) \
			&& open -n /Applications/$(PRODUCT); then \
			rm -rf "$$install_dir"; \
		else \
			rm -rf /Applications/$(PRODUCT); \
			if [ -d "$$install_dir/$(PRODUCT).previous" ]; then \
				mv "$$install_dir/$(PRODUCT).previous" /Applications/$(PRODUCT); \
			fi; \
			rmdir "$$install_dir"; \
			exit 1; \
		fi

stable-install: stable-sign
	@$(MAKE) install \
		CODESIGN_IDENTITY="$(STABLE_CODESIGN_IDENTITY)" \
		EXPECTED_TEAM_ID="$(STABLE_TEAM_ID)"

package: sign
	@rm -rf dist/dmg-root
	@mkdir -p dist/dmg-root
	@cp -R dist/$(PRODUCT) dist/dmg-root/$(PRODUCT)
	@ln -s /Applications dist/dmg-root/Applications
	@hdiutil create dist/$(APP_NAME).dmg -volname "$(APP_DISPLAY_NAME)" -fs APFS -srcfolder dist/dmg-root -ov -format UDZO
	@rm -rf dist/dmg-root

clean:
	swift package reset
	rm -rf $(BUILD_DIR) dist
