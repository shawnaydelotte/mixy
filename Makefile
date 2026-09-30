# Mixy — build and test from the command line.
# xcode-select may point at Command Line Tools; pin the installed Xcode 27.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
PROJECT       := mixy.xcodeproj
SCHEME        := mixy
DEST          := platform=macOS,arch=arm64
DERIVED       ?= $(CURDIR)/.derived

export DEVELOPER_DIR

.PHONY: list build test test-hal run clean inventory

list:
	xcodebuild -list -project $(PROJECT)

build:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath $(DERIVED)

test:
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -derivedDataPath $(DERIVED)

test-hal:
	xcodebuild build -project $(PROJECT) -scheme MixyHAL -destination '$(DEST)' -derivedDataPath $(DERIVED)

run: build
	open $(DERIVED)/Build/Products/Debug/mixy.app

inventory: build
	MIXY_QUIT_AFTER_INVENTORY=1 $(DERIVED)/Build/Products/Debug/mixy.app/Contents/MacOS/mixy

clean:
	rm -rf $(DERIVED)
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME)
