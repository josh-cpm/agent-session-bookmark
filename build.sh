#!/bin/zsh
# Build "Agent Session Bookmark.app" into ./build with the system Swift toolchain.
# The Python feed and flag scripts are copied into the bundle's Resources, so the
# built app is self-contained.
# Usage: ./build.sh [--run]     (--run relaunches the app after building)
set -euo pipefail

HERE="${0:A:h}"
SRC="$HERE/AgentSessionBookmark"
OUT="$HERE/build"
APP="$OUT/Agent Session Bookmark.app"
BIN="$APP/Contents/MacOS/AgentSessionBookmark"
RES="$APP/Contents/Resources"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

arch="$(uname -m)"   # arm64 or x86_64
mkdir -p "$APP/Contents/MacOS" "$RES"

echo "compiling ($arch)…"
swiftc -O -swift-version 5 \
  -target "$arch-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework CoreServices \
  -o "$BIN" \
  "$SRC/Model.swift" "$SRC/Views.swift" "$SRC/main.swift"

cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
for f in sessions_feed.py flag.py transcripts.py asb_paths.py; do
  cp "$HERE/$f" "$RES/$f"
done
chmod +x "$RES/sessions_feed.py" "$RES/flag.py"

if [[ ! -f "$OUT/AppIcon.icns" ]]; then
  echo "rendering icon…"
  swift "$HERE/make_icon.swift" "$OUT/AppIcon.iconset" && iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$RES/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc codesign skipped)"

echo "built: $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x AgentSessionBookmark 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "launched"
fi
