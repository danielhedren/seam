.PHONY: setup check format lint build test prove test-github test-all app release run install uninstall dist strings

setup:
	git config core.hooksPath .githooks

check: lint build test

SWIFT_SOURCES = Package.swift Sources Tests App

lint:
	swift format lint --strict --recursive $(SWIFT_SOURCES)

format:
	swift format --in-place --recursive $(SWIFT_SOURCES)

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

# A tagged release zip and the cask pointing at it; ad-hoc signed, not notarized (SPEC §13.1).
dist: check release
	Scripts/dist.sh $(RELEASE_APP)

strings:
	Scripts/sync-strings.sh

# Opt-in suites (SPEC §10): the real-repo acceptance check and performance budgets. Budgets run
# in their own invocation so other tests' git processes don't skew the timings. The real repo
# is described in local.mk, which stays out of git; without it those checks skip.
-include local.mk
REAL_ENV = SEAM_REAL_REPO="$(REAL_REPO)" SEAM_REAL_COMMIT="$(REAL_COMMIT)" \
	SEAM_REAL_BRANCH="$(REAL_BRANCH)" SEAM_REAL_PARENT="$(REAL_PARENT)" \
	SEAM_REAL_BASE="$(REAL_BASE)" SEAM_REAL_STAT="$(REAL_STAT)"

# Reads the real repo's pull requests with the user's own gh (SPEC §7.8): network and a login.
# The tests matching FILTER fail without the uncommitted change under Sources/ and pass with it.
prove:
	Scripts/prove-test.sh '$(FILTER)'

test-github:
	$(REAL_ENV) SEAM_REAL_GITHUB=1 swift test --filter RealGitHub

test-all: check app
	$(REAL_ENV) swift test --skip 'Budget|Benchmark'
	$(REAL_ENV) SEAM_BENCH=1 swift test -c release -Xswiftc -enable-testing \
		--filter 'Budget|Benchmark'
	SEAM_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter LiveReload
