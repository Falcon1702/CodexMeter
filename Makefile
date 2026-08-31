DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
XCODEBUILD := $(DEVELOPER_DIR)/usr/bin/xcodebuild
ROOT := $(CURDIR)

.PHONY: project build test direct-smoke bridge-demo snapshot-demo preview

project:
	xcodegen generate --spec project.yml

build:
	$(XCODEBUILD) -quiet -project WatchOverlay.xcodeproj -target WatchOverlay -configuration Debug CODE_SIGNING_ALLOWED=NO SYMROOT='$(ROOT)/.build/XcodeProducts' OBJROOT='$(ROOT)/.build/XcodeIntermediates' build

test:
	cd bridge && npm test
	DEVELOPER_DIR=$(DEVELOPER_DIR) /usr/bin/xcrun swift test --package-path Packages/UsageCore --scratch-path Packages/UsageCore/.build/xcode-swift-tests
	$(MAKE) direct-smoke

direct-smoke:
	mkdir -p '$(ROOT)/.build/DirectSmoke'
	DEVELOPER_DIR=$(DEVELOPER_DIR) /usr/bin/xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=minimal \
		Apps/iOS/LoginTransportRetryPolicy.swift \
		Apps/iOS/CodexDirectModels.swift \
		Apps/iOS/CodexDirectResponseParser.swift \
		Apps/iOS/CodexDirectCredentialStore.swift \
		Apps/iOS/CodexDirectClient.swift \
		Tools/CodexDirectSmoke/main.swift \
		-o '$(ROOT)/.build/DirectSmoke/CodexDirectSmoke'
	'$(ROOT)/.build/DirectSmoke/CodexDirectSmoke'

bridge-demo:
	cd bridge && npm run serve

snapshot-demo:
	cd bridge && npm run snapshot

preview:
	DEVELOPER_DIR=$(DEVELOPER_DIR) /usr/bin/xcrun swift run --package-path Tools/WatchLayoutPreview WatchLayoutPreview docs/design/v1-layout-preview.png
