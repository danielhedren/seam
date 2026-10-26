#!/bin/sh
# Builds a release of Seam from a clean, checked commit (SPEC §13.1): tags it v<version>, zips
# the Release app and points Casks/seam.rb at the zip. Publishing stays a manual step.
# Usage: Scripts/dist.sh <Seam.app> (after make check and make release).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
cask="$root/Casks/seam.rb"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
tag="v$version"

# A release is exactly a commit: anything uncommitted would ship without being in it.
if [ -n "$(git -C "$root" status --porcelain)" ]; then
    echo "dist.sh: commit or stash your changes first" >&2
    exit 1
fi
if [ "$build" != "$(git -C "$root" rev-list --count HEAD)" ]; then
    echo "dist.sh: $app wasn't built from HEAD; run make release" >&2
    exit 1
fi
if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "dist.sh: $tag exists; raise MARKETING_VERSION in App/Seam/Seam.xcconfig" >&2
    exit 1
fi

mkdir -p "$root/.build/dist"
zip="$root/.build/dist/Seam-$version.zip"
rm -f "$zip"
# ditto keeps the bundle's symlinks and signature, which zip can break.
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
git -C "$root" tag -a "$tag" -m "Seam $version"
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"

echo "Wrote $zip ($version, build $build)"
echo "sha256 $sha"
echo "Tagged $tag and updated Casks/seam.rb. To publish:"
echo "  git push origin main $tag"
echo "  gh release create $tag '$zip' --title 'Seam $version'"
echo "  git commit -m 'chore: release $version' Casks/seam.rb && git push"
