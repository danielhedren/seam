#!/bin/sh
# Builds and tests the targets Package.swift lists as portable, in Linux under Docker (ADR 0007).
# The checkout is mounted read-only and copied in, so the host's .build is never touched; the
# Linux build is kept between runs in a Docker volume.
set -eu
image="swift:6.4-noble"
command -v docker >/dev/null || { echo "linux-check needs Docker" >&2; exit 1; }
cache="seam-linux-$(basename "$PWD")"
docker run --rm -v "$PWD:/src:ro" -v "$cache:/build" "$image" sh -c '
    set -eu
    mkdir /work
    tar -C /src --exclude=./.build --exclude=./.git -cf - . | tar -C /work -xf -
    cd /work
    swift build --build-tests --scratch-path /build
    swift test --skip-build --scratch-path /build
'
