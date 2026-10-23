# Cue — run `make run` for a local debug build with isolated data.
-include .env
export

DERIVED := build/DerivedData
SIGNING := $(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development",)
XCODEBUILD := xcodebuild -project Cue.xcodeproj -scheme Cue -derivedDataPath $(DERIVED) $(SIGNING)

.PHONY: run build project test test-unit test-ui dmg clean

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
	$(XCODEBUILD) -configuration Debug -only-testing:CueUITests -retry-tests-on-failure -test-iterations 3 test

# Signed, notarized DMG plus Sparkle appcast in build/release. See docs/release-process.md.
dmg: project
	scripts/release.sh

clean:
	rm -rf build CueKit/.build
