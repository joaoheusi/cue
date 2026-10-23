# Cue — run `make run` for a local debug build with isolated data.
-include .env
export

DERIVED := build/DerivedData
SIGNING := $(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development",)
XCODEBUILD := xcodebuild -project Cue.xcodeproj -scheme Cue -derivedDataPath $(DERIVED) CUE_UPDATE_URL="$(CUE_UPDATE_URL)" $(SIGNING)

.PHONY: run build project test test-unit test-ui release dmg clean

run: build
	open "$(DERIVED)/Build/Products/Debug/Cue.app"

build: project
	$(XCODEBUILD) -configuration Debug build

# Regenerates the Xcode project from project.yml when XcodeGen is installed.
project:
	@if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi

test: test-unit test-ui

test-unit:
	swift test --package-path CueKit

test-ui: project
	$(XCODEBUILD) -configuration Debug -only-testing:CueUITests test

# Release signing: set DEVELOPMENT_TEAM and APPLE_SIGNING_IDENTITY ("Developer ID Application: …") in .env.
RELEASE_SIGNING := $(if $(APPLE_SIGNING_IDENTITY),CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(APPLE_SIGNING_IDENTITY)" OTHER_CODE_SIGN_FLAGS=--timestamp,)

release: project
	$(XCODEBUILD) -configuration Release $(RELEASE_SIGNING) build
	codesign --verify --strict --verbose=1 "$(DERIVED)/Build/Products/Release/Cue.app"
	@echo "Built $(DERIVED)/Build/Products/Release/Cue.app"

# Drag-to-Applications disk image. Notarize it before sharing (see docs/release-process.md).
dmg: release
	rm -rf build/dmg build/Cue.dmg && mkdir -p build/dmg
	cp -R "$(DERIVED)/Build/Products/Release/Cue.app" build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Cue -srcfolder build/dmg -ov -format UDZO build/Cue.dmg

clean:
	rm -rf build CueKit/.build
