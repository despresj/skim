.PHONY: all rust swift xcode clean run dev dist setup

RUST_LIB = target/release/libskim_core.a
DERIVED_DATA = Skim/build/DerivedData
APP_BUNDLE = $(DERIVED_DATA)/Build/Products/Release/Skim.app
DIST_DIR = dist
DIST_ZIP = $(DIST_DIR)/Skim.zip

all: rust xcode swift

# Build Rust library
rust:
	cargo build --release

# Generate Xcode project (requires xcodegen: brew install xcodegen)
xcode:
	cd Skim && xcodegen generate

# Build Swift app
swift: rust xcode
	xcodebuild -project Skim/Skim.xcodeproj \
		-scheme Skim \
		-configuration Release \
		-derivedDataPath "$(DERIVED_DATA)" \
		build

# Run the app
run: swift
	open "$(APP_BUNDLE)"

# Development build (faster)
dev:
	cargo build
	cd Skim && xcodegen generate
	xcodebuild -project Skim/Skim.xcodeproj \
		-scheme Skim \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		build
	open "$(DERIVED_DATA)/Build/Products/Debug/Skim.app"

# Clean all build artifacts
clean:
	cargo clean
	rm -rf Skim/Skim.xcodeproj
	rm -rf Skim/build
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
