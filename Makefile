.PHONY: all rust swift xcode clean run

RUST_LIB = target/release/libspeed_reader_core.a

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
		build

# Run the app
run: swift
	open SpeedReader/build/Release/Speed\ Reader.app

# Development build (faster)
dev:
	cargo build
	cd SpeedReader && xcodegen generate
	xcodebuild -project SpeedReader/SpeedReader.xcodeproj \
		-scheme SpeedReader \
		-configuration Debug \
		build
	open SpeedReader/build/Debug/Speed\ Reader.app

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
