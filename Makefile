APP_NAME := DiskAnalyzer
BUNDLE_ID := dev.local.diskanalyzer

APP_DIR := $(APP_NAME).app
CONTENTS := $(APP_DIR)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
INFOPLIST := $(CONTENTS)/Info.plist

BIN_PATH := $(shell swift build -c release --show-bin-path 2>/dev/null)/$(APP_NAME)

.PHONY: all app run install clean debug

all: app

# --- Build the .app bundle ---
app: build
	@echo "→ Assembling $(APP_DIR)…"
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(MACOS)" "$(RESOURCES)"
	cp "$(BIN_PATH)" "$(MACOS)/$(APP_NAME)"
	chmod +x "$(MACOS)/$(APP_NAME)"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n' > "$(INFOPLIST)"
	printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"\n' >> "$(INFOPLIST)"
	printf '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' >> "$(INFOPLIST)"
	printf '<plist version="1.0">\n<dict>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleName</key><string>$(APP_NAME)</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleDisplayName</key><string>Disk Analyzer</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleExecutable</key><string>$(APP_NAME)</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundlePackageType</key><string>APPL</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleShortVersionString</key><string>1.0.0</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>CFBundleVersion</key><string>1</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>LSMinimumSystemVersion</key><string>13.0</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>NSHighResolutionCapable</key><true/>\n' >> "$(INFOPLIST)"
	printf '\t<key>NSPrincipalClass</key><string>NSApplication</string>\n' >> "$(INFOPLIST)"
	printf '\t<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>\n' >> "$(INFOPLIST)"
	printf '</dict>\n</plist>\n' >> "$(INFOPLIST)"
	@codesign --force --sign - --timestamp=none "$(APP_DIR)" >/dev/null 2>&1 || true
	@echo "✓ Built $(APP_DIR)"
build:
	@echo "→ Building release binary…"
	swift build -c release
	@echo "✓ Build complete"
# --- Build + launch ---
run: app
	@echo "→ Launching $(APP_DIR)…"
	@open "$(APP_DIR)"
# --- Install to /Applications ---
install: app
	@echo "→ Installing to /Applications…"
	cp -R "$(APP_DIR)" /Applications/
	@echo "✓ Installed to /Applications/$(APP_DIR)"

# --- Clean ---
clean:
	@echo "→ Cleaning build artifacts…"
	rm -rf "$(APP_DIR)"
	swift package clean
	@echo "✓ Cleaned"

# --- Debug build (no .app, CLI binary only) ---
debug:
	swift build
