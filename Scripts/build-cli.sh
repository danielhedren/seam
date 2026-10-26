#!/bin/sh
# Builds the `seam` command and the licence notices into the app's resources (SPEC §13). Run by
# the app target's build phase; Xcode can't copy a package's executable product into a bundle.
set -eu
config=$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')
package="$SRCROOT/.."
# Its own scratch path, so it never waits on a `swift build` running in the checkout.
scratch="$OBJROOT/seam-cli"
# Xcode's environment points at its own toolchain settings, which SwiftPM must not inherit.
unset SDKROOT TOOLCHAINS
xcrun swift build --package-path "$package" --scratch-path "$scratch" -c "$config" --product seam
bin=$(xcrun swift build --package-path "$package" --scratch-path "$scratch" -c "$config" \
    --show-bin-path)
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
destination="$resources/seam"
install -m 755 "$bin/seam" "$destination"
"$package/Scripts/notices.sh" "$scratch/checkouts" "$resources/Notices.txt"
# Signed on its own: the app's signature covers its resources, not code inside them.
codesign --force --sign - "$destination"
