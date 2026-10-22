.PHONY: setup check format lint build test test-all app run strings

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
	swift test

# The thin Xcode app target (SPEC §8.1); everything else builds with SwiftPM.
app:
	@echo "Building Seam.app (the first build compiles the tree-sitter grammars, a few minutes)"
	Scripts/build.sh xcodebuild -project App/Seam.xcodeproj -scheme Seam -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build

# Release, because the performance budgets (SPEC §8.7) describe the optimised app.
run:
	@echo "Building Seam.app in Release (the first build compiles the tree-sitter grammars)"
	Scripts/build.sh xcodebuild -project App/Seam.xcodeproj -scheme Seam -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
	@# open only activates a running instance, which would keep the old build.
	@pkill -f "$$PWD/.build/xcode/Build/Products/Release/Seam.app/Contents/MacOS/Seam" && \
		while pgrep -f "$$PWD/.build/xcode/Build/Products/Release/Seam.app/Contents/MacOS/Seam" >/dev/null; do sleep 0.1; done; true
	open .build/xcode/Build/Products/Release/Seam.app --args "$${REPO:-$$PWD}"

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
