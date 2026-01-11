.PHONY: all rust swift xcode clean run dev dist setup

RUST_LIB = target/release/libspeed_reader_core.a
DERIVED_DATA = SpeedReader/build/DerivedData
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/Release/Speed Reader.app
DIST_DIR = dist
DIST_ZIP = $(DIST_DIR)/SpeedReader.zip

all: rust xcode swift

# Build Rust library
rust:
	cargo build --release

# Generate Xcode project (requires xcodegen: brew install xcodegen)
xcode:
	cd SpeedReader && xcodegen generate

# Build Swift app
swift: rust xcode
	xcodebuild -project SpeedReader/SpeedReader.xcodeproj \
		-scheme SpeedReader \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

# Run the app
run: swift
	open "$(APP_BUNDLE)"

# Development build (faster)
dev:
	cargo build
	cd SpeedReader && xcodegen generate
	xcodebuild -project SpeedReader/SpeedReader.xcodeproj \
		-scheme SpeedReader \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		build
	open "$(DERIVED_DATA)/Build/Products/Debug/Speed Reader.app"

# Clean all build artifacts
clean:
	cargo clean
	rm -rf SpeedReader/SpeedReader.xcodeproj
	rm -rf SpeedReader/build
	rm -rf generated

# Setup: install dependencies
setup:
	@echo "Installing xcodegen..."
	brew install xcodegen || true
	@echo "Done! Run 'make' to build."

# Build release artifact for GitHub/Homebrew
dist: swift
	mkdir -p "$(DIST_DIR)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(DIST_ZIP)"
	shasum -a 256 "$(DIST_ZIP)" | awk '{print $$1}' > "$(DIST_ZIP).sha256"
	@echo "Created $(DIST_ZIP)"
	@echo "sha256: $$(cat "$(DIST_ZIP).sha256")"
