#!/usr/bin/env bash
# Build and launch the Mac desk push-to-talk floater for this Firstmate home.
#
# Usage:
#   fm-desk-floater.sh [--build-only]
#   fm-desk-floater.sh --help
#
# Requires macOS with Swift 5.9+, microphone permission on first use, and
# DEEPGRAM_API_KEY in the environment or this home's gitignored .env.
# See docs/desk-floater.md.
#
# Builds desk-floater/ into a minimal .app under desk-floater/.build/DeskFloater.app
# so TCC microphone prompts have an NSMicrophoneUsageDescription.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
PKG="$ROOT/desk-floater"
RELEASE_BIN="$PKG/.build/release/DeskFloater"
APP_DIR="$PKG/.build/DeskFloater.app"
APP_MACOS="$APP_DIR/Contents/MacOS"
APP_BIN="$APP_MACOS/DeskFloater"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-desk-floater: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

write_info_plist() {
  cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.firstmate.desk-floater</string>
  <key>CFBundleName</key>
  <string>DeskFloater</string>
  <key>CFBundleExecutable</key>
  <string>DeskFloater</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Desk floater records push-to-talk audio so Firstmate can hear your captain input via Deepgram.</string>
</dict>
</plist>
PLIST
}

assemble_app() {
  mkdir -p "$APP_MACOS"
  cp "$RELEASE_BIN" "$APP_BIN"
  chmod +x "$APP_BIN"
  write_info_plist
}

build() {
  command -v swift >/dev/null 2>&1 || die "swift is not installed"
  [ "$(uname -s)" = Darwin ] || die "the desk floater is macOS-only"
  note "building DeskFloater (release)"
  (
    cd "$PKG"
    swift build -c release --product DeskFloater
  ) || die "swift build failed"
  [ -x "$RELEASE_BIN" ] || die "expected binary missing: $RELEASE_BIN"
  assemble_app
}

needs_build() {
  [ ! -x "$APP_BIN" ] && return 0
  [ "$PKG/Sources/DeskFloater.swift" -nt "$APP_BIN" ] && return 0
  [ "$PKG/Package.swift" -nt "$APP_BIN" ] && return 0
  return 1
}

main() {
  local build_only=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --build-only) build_only=true; shift ;;
      -*) die "unexpected option: $1" ;;
      *) die "unexpected argument: $1" ;;
    esac
  done

  if needs_build; then
    build
  fi

  if [ "$build_only" = true ]; then
    printf '%s\n' "$APP_DIR"
    exit 0
  fi

  export FM_HOME
  export FM_DESK_FLOATER_ROOT="$ROOT"
  note "launching floater for FM_HOME=$FM_HOME"
  if ! open --env FM_HOME="$FM_HOME" --env FM_DESK_FLOATER_ROOT="$ROOT" "$APP_DIR"; then
    note "open --env failed; launching the bundle binary directly"
    "$APP_BIN" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

main "$@"
