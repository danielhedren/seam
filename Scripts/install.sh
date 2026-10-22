#!/bin/sh
# Installs a built Seam.app into ~/Applications and links the seam command (SPEC §13).
# Usage: Scripts/install.sh install <Seam.app> | Scripts/install.sh uninstall
set -eu
apps="$HOME/Applications"
dest="$apps/Seam.app"
link="$HOME/.local/bin/seam"
script="$dest/Contents/Resources/seam"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The same rule as CommandLineTool: only a symlink to some Seam.app's script is ours to replace.
link_is_seams() {
    [ -L "$link" ] && case "$(readlink "$link")" in *.app/Contents/Resources/seam) true ;; *) false ;; esac
}

running() { pgrep -f "$dest/Contents/MacOS/Seam" >/dev/null; }

# Only the installed copy; a build-dir instance keeps running.
quit() {
    pkill -f "$dest/Contents/MacOS/Seam" || return 0
    while running; do sleep 0.1; done
}

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$dest/Contents/Info.plist"; }

install() {
    [ -d "$1/Contents/MacOS" ] || { echo "install.sh: no app at $1" >&2; exit 1; }
    mkdir -p "$apps"
    # Copy first and swap after, so a failed copy leaves the installed app intact.
    staged="$apps/.Seam.app.new"
    old="$apps/.Seam.app.old"
    rm -rf "$staged" "$old"
    ditto "$1" "$staged"
    relaunch=false
    if running; then relaunch=true; fi
    quit
    [ ! -e "$dest" ] || mv "$dest" "$old"
    mv "$staged" "$dest"
    rm -rf "$old"
    "$lsregister" -f "$dest"
    if link_is_seams || { [ ! -e "$link" ] && [ ! -L "$link" ]; }; then
        mkdir -p "$(dirname "$link")"
        ln -sfh "$script" "$link"
        echo "Linked $link -> $script"
    else
        echo "Left $link alone: it isn't a link to Seam's seam command" >&2
    fi
    echo "Installed Seam $(plist CFBundleShortVersionString) ($(plist CFBundleVersion)) at $dest"
    if $relaunch; then open "$dest"; fi
}

uninstall() {
    quit
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$script" ]; then
        rm "$link"
        echo "Removed $link"
    fi
    if [ -e "$dest" ]; then
        "$lsregister" -u "$dest"
        rm -rf "$dest"
        echo "Removed $dest"
    fi
}

case "${1:-}" in
    install) install "${2:?usage: install.sh install <Seam.app>}" ;;
    uninstall) uninstall ;;
    *)
        echo "usage: install.sh install <Seam.app> | install.sh uninstall" >&2
        exit 64
        ;;
esac
