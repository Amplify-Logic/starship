#!/usr/bin/env bash
# Strict no-emit contract check for all tracked Pi primary extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for Pi extension typecheck"; exit 0; }
TSC_VERSION=$(tsc --version 2>/dev/null | awk '{ print $2 }')
TSC_MAJOR=${TSC_VERSION%%.*}
case "$TSC_MAJOR" in
  ''|*[!0-9]*) echo "skip: could not identify the installed TypeScript compiler"; exit 0 ;;
esac
if [ "$TSC_MAJOR" -lt 5 ]; then
  echo "skip: TypeScript $TSC_VERSION cannot parse the installed Pi declarations; version 5 or newer is required"
  exit 0
fi

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] \
  || [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ] \
  || [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ]; then
  echo "not ok - installed Pi package is missing typebox, Pi TUI, or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-status-bar.ts" "$TMP_ROOT/fm-primary-status-bar.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || {
  echo "not ok - Pi primary extension typecheck failed" >&2
  exit 1
}
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - Pi primary extensions pass strict no-emit typecheck against Pi %s\n' "$version"
