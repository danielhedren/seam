.PHONY: setup check format lint build test test-all app release run install uninstall dist strings

setup:
	git config core.hooksPath .githooks

check: lint build test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests App

format:
	swift format --in-place --recursive Package.swift Sources Tests App

build:
	Scripts/build.sh swift build

test:
	Scripts/build.sh swift build --build-tests
	swift test --skip-build

# The thin Xcode app target (SPEC §8.1); everything else builds with SwiftPM. The build number
# is the commit count, so builds from different commits are distinguishable.
XCODEBUILD = Scripts/build.sh xcodebuild -project App/Seam.xcodeproj -scheme Seam \
	-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
	CURRENT_PROJECT_VERSION=$$(git rev-list --count HEAD)
RELEASE_APP = .build/xcode/Build/Products/Release/Seam.app

app:
	@echo "Building Seam.app (the first build compiles the tree-sitter grammars, a few minutes)"
	$(XCODEBUILD) -configuration Debug build

# Release, because the performance budgets (SPEC §8.7) describe the optimised app.
release:
	@echo "Building Seam.app in Release (the first build compiles the tree-sitter grammars)"
	$(XCODEBUILD) -configuration Release build

run: release
	@# open only activates a running instance, which would keep the old build.
	@pkill -f "$$PWD/$(RELEASE_APP)/Contents/MacOS/Seam" && \
		while pgrep -f "$$PWD/$(RELEASE_APP)/Contents/MacOS/Seam" >/dev/null; do sleep 0.1; done; true
	open $(RELEASE_APP) --args "$${REPO:-$$PWD}"

install: release
	Scripts/install.sh install $(RELEASE_APP)

uninstall:
	Scripts/install.sh uninstall

# Ad-hoc signed and not notarized (SPEC §13).
dist: release
	@mkdir -p .build/dist
	@plist=$(RELEASE_APP)/Contents/Info.plist; \
	version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $$plist); \
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $$plist); \
	zip=.build/dist/Seam-$$version-$$build.zip; \
	rm -f $$zip && ditto -c -k --keepParent $(RELEASE_APP) $$zip && echo "Wrote $$zip"

strings:
	Scripts/sync-strings.sh

# Opt-in suites (SPEC §10): the real-repo acceptance check and performance budgets. Budgets run
# in their own invocation so other tests' git processes don't skew the timings.
REAL_REPO ?= $(HOME)/Code/work-repo/.worktrees/feat-b

test-all: check app
	SEAM_REAL_REPO=$(REAL_REPO) swift test --skip 'Budget|Benchmark'
	SEAM_REAL_REPO=$(REAL_REPO) SEAM_BENCH=1 swift test -c release -Xswiftc -enable-testing \
		--filter 'Budget|Benchmark'
	SEAM_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter LiveReload
