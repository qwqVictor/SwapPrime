#!/bin/sh
# Build SwapPrime.app from swap_prime.m (menu-bar swap-priming tool).
#
# Build only — the app installs itself, no install logic lives here:
#   SwapPrime.app/Contents/MacOS/SwapPrime --install     copy to ~/Applications,
#                                                        write + load LaunchAgent
#   SwapPrime.app/Contents/MacOS/SwapPrime --uninstall   remove both
#
# The LaunchAgent runs SwapPrime at every login with a 60s timeout. Swap
# must be re-primed every boot (swapfile0 doesn't persist across reboot), so
# leave it installed for the lifetime of the fix.
set -e
cd "$(dirname "$0")"

SRC=swap_prime.m
BIN=SwapPrime
APP="$BIN.app"

build() {
    # Version tracks the nearest git tag (leading "v" stripped), so the
    # packaged app matches the GitHub release it ships in (v0.2 → 0.2).
    local VERSION
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    [ -n "$VERSION" ] || VERSION="0.0.0"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    xcrun clang -fobjc-arc -O2 -Wall -Wextra "$SRC" \
        -framework Cocoa -mmacosx-version-min=11.0 \
        -Wno-deprecated-declarations \
        -o "$APP/Contents/MacOS/$BIN"
    cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SwapPrime</string>
    <key>CFBundleIdentifier</key><string>tech.imvictor.swapprime</string>
    <key>CFBundleName</key><string>SwapPrime</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
    echo "built: $APP (version $VERSION)"
    echo "install: $APP/Contents/MacOS/$BIN --install"
}

case "${1:-build}" in
    build)
        build
        ;;
    *)
        echo "usage: $0 [build]"
        echo "install/uninstall moved into the app:"
        echo "  $APP/Contents/MacOS/$BIN --install"
        echo "  $APP/Contents/MacOS/$BIN --uninstall"
        exit 2
        ;;
esac
