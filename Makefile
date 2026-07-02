SHELL := /bin/bash

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

vendor: ## Build whisper.cpp static libs into Vendor/ (one-time)
	[ -d Vendor/whisper/lib ] || ./scripts/vendor-whisper.sh

models: ## Fetch whisper + VAD models to Application Support
	./scripts/fetch-voice-models.sh

test-voice: vendor gen ## Opt-in voice tests (needs Vendor/ + models)
	set -o pipefail; xcodebuild -project $(PROJECT).xcodeproj -scheme VoiceGatewayTests \
	  -derivedDataPath $(DD) -destination 'platform=macOS' test | tail -20

.PHONY: gen build test run vendor models test-voice
