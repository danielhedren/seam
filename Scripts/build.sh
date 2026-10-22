#!/bin/sh
# Runs a build, shows one line per compiled file, and fails on any warning (AGENTS.md: the
# build stays clean). Usage: Scripts/build.sh swift build | Scripts/build.sh xcodebuild ...
set -eu
log="$(mktemp)"
status_file="$(mktemp)"
trap 'rm -f "$log" "$status_file"' EXIT
# A pipeline's status is its last command's, so the build's own status goes through a file.
{ "$@" 2>&1 || echo "$?" >"$status_file"; } | tee "$log" | sed -nE \
    -e 's/^.*Compiling ([^ ]+) .*$/  compile \1/p' \
    -e 's/^(CompileC|SwiftCompile) .* ([^ /]+\.(c|swift)) .*/  compile \2/p' \
    -e 's/^\*\* (BUILD [A-Z]+) \*\*$/\1/p' \
    -e 's/^(Build complete!.*)$/\1/p'
status="$(cat "$status_file")"
# The only allowed line: Apple's App Intents step prints this for every app that doesn't use
# App Intents, and no build setting turns it off.
warnings="$(grep -E '(warning|error):' "$log" \
    | grep -v 'Metadata extraction skipped, no AppIntents.framework dependency found' || true)"
if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings" | sort -u
    exit 1
fi
[ "${status:-0}" -eq 0 ] || { tail -20 "$log"; exit "$status"; }
