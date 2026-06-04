PROJECT = ZielVanSebastian
DD = build
APP = $(DD)/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -configuration Debug \
	  -derivedDataPath $(DD) -destination 'platform=macOS' build

test: gen
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -configuration Debug \
	  -derivedDataPath $(DD) -destination 'platform=macOS' test

run: build
	./$(APP) --window --demo

.PHONY: gen build test run
