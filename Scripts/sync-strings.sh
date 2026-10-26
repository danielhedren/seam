#!/bin/sh
# Updates each module's String Catalog from the keys the Xcode build extracted (SPEC §9).
# swift build doesn't extract keys, so this runs `make app` first.
set -eu
cd "$(dirname "$0")/.."
make app
for module in DiffModel DiffView ReviewModel Features; do
    objects=".build/xcode/Build/Intermediates.noindex/Seam.build/Debug/$module-t.build/Objects-normal/arm64"
    set --
    for file in "$objects"/*.stringsdata; do set -- "$@" --stringsdata "$file"; done
    xcrun xcstringstool sync "Sources/$module/Resources/Localizable.xcstrings" "$@"
done
