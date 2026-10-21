.PHONY: setup check format lint build test test-all app run strings

setup:
	git config core.hooksPath .githooks

check: lint build test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests App

format:
	swift format --in-place --recursive Package.swift Sources Tests App

build:
	swift build

test:
	swift test

# The thin Xcode app target (SPEC §8.1); everything else builds with SwiftPM.
app:
	xcodebuild -quiet -project App/Seam.xcodeproj -scheme Seam -configuration Debug \
		-derivedDataPath .build/xcode build

run: app
	open .build/xcode/Build/Products/Debug/Seam.app --args "$${REPO:-$$PWD}"

strings:
	Scripts/sync-strings.sh

# Opt-in suites (SPEC §10): the real-repo acceptance check and performance budgets.
test-all: check app
	SEAM_REAL_REPO=$${SEAM_REAL_REPO:-$$HOME/Code/work-repo/.worktrees/feat-b} \
	SEAM_BENCH=1 swift test
