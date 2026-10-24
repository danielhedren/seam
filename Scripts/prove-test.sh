#!/bin/sh
# Shows that the tests matching a filter fail without the uncommitted change under Sources/ and
# pass with it (AGENTS.md: a test that passes before and after is not evidence).
#   Scripts/prove-test.sh 'aRefChangeReloadsTheShownDiff'
set -eu

filter=${1:?usage: Scripts/prove-test.sh <test filter>}
work=$(mktemp -d)
git diff --binary -- Sources > "$work/change.patch"
git ls-files --others --exclude-standard -- Sources > "$work/new-files"
if [ ! -s "$work/change.patch" ] && [ ! -s "$work/new-files" ]; then
    echo "No uncommitted change under Sources/ to take away." >&2
    exit 2
fi

restore() {
    git checkout -- Sources
    if [ -s "$work/change.patch" ]; then git apply "$work/change.patch"; fi
    while IFS= read -r file; do
        mkdir -p "$(dirname "$file")"
        mv "$work/new/$file" "$file"
    done < "$work/new-files"
}
trap restore EXIT

while IFS= read -r file; do
    mkdir -p "$work/new/$(dirname "$file")"
    mv "$file" "$work/new/$file"
done < "$work/new-files"
git checkout -- Sources

echo "== Without the change"
if ! Scripts/build.sh swift build --build-tests > "$work/build.log" 2>&1; then
    echo "The tests don't compile without the change: inconclusive, not proof." >&2
    grep -m 5 "error:" "$work/build.log" >&2 || true
    exit 3
fi
if swift test --skip-build --filter "$filter" > "$work/without.log" 2>&1; then
    echo "FAIL: '$filter' passes without the change, so it doesn't prove it." >&2
    exit 1
fi
grep -E "^✘ Test .*(recorded an issue|Expectation)" "$work/without.log" | head -5

restore
trap - EXIT
echo "== With the change"
Scripts/build.sh swift build --build-tests > "$work/build.log" 2>&1
if ! swift test --skip-build --filter "$filter" > "$work/with.log" 2>&1; then
    echo "FAIL: '$filter' fails with the change too." >&2
    grep -E "^✘" "$work/with.log" | head -5 >&2
    exit 1
fi
echo "OK: '$filter' fails without the change and passes with it."
