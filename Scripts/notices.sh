#!/bin/sh
# Writes the licences of Seam and of the code it ships with into one file, which MIT and
# Apache-2.0 require to travel with the app. Usage: Scripts/notices.sh <checkouts dir> <output>
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="$1"
out="$2"
section() {
    [ -f "$2" ] || { echo "notices.sh: no licence at $2" >&2; exit 1; }
    printf '\n\n## %s\n\n' "$1"
    cat "$2"
}
{
    printf '# Seam\n\n'
    cat "$root/LICENSE"
    printf '\n\n# Third-party software\n'
    # Only what the app ships; the test-only packages stay out.
    section SwiftTreeSitter "$checkouts/SwiftTreeSitter/LICENSE"
    section tree-sitter "$checkouts/tree-sitter/LICENSE"
    section swift-argument-parser "$checkouts/swift-argument-parser/LICENSE.txt"
    section "Primer Octicons" "$root/Sources/Features/Resources/Octicons/Octicons-LICENSE"
    for grammar in "$root"/Vendor/Grammars/*/; do
        name=$(basename "$grammar")
        section "tree-sitter-$name grammar" "$grammar/LICENSE"
    done
} >"$out"
