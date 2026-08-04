#!/bin/bash
# Builds MacSCP.app.
#
# There is no Xcode on this machine, so we assemble the bundle by hand around
# the SPM executable. A SwiftUI app does not strictly need a bundle to launch,
# but without one it gets no Dock icon, no menu bar, and no window focus.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/MacSCP.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/MacSCP"
if [[ ! -x "$BIN" ]]; then
    echo "error: expected executable at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacSCP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MacSCP</string>
    <key>CFBundleDisplayName</key>       <string>MacSCP</string>
    <key>CFBundleIdentifier</key>        <string>local.macscp</string>
    <key>CFBundleExecutable</key>        <string>MacSCP</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local launch, not for distribution.
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "note: ad-hoc codesign failed; the app may still run"

echo "==> Built $APP"
echo "    open '$APP'"
