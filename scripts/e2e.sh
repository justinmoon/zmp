#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test for ZMP on Android.
# - Builds the zmp CLI in a nix dev shell
# - Creates a fresh temp project
# - Starts a local HTTP server on the chosen PORT
# - Runs `zmp dev android` which auto-provisions an emulator if needed

PORT="${PORT:-8085}"
APP_NAME="${APP_NAME:-zmp_e2e_demo}"
APP_ID="${APP_ID:-com.example.zmpe2e}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "error: missing '$1'"; exit 1; }; }
require python3
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  echo "error: must be run inside nix develop (or direnv). Try: nix develop"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

echo "[1/5] Building zmp CLI"
require zig
zig build -Doptimize=ReleaseSafe

echo "[2/5] Creating temp project"
TMPDIR="$(mktemp -d -t zmp-e2e.XXXXXX)"
echo "- temp dir: $TMPDIR"
pushd "$TMPDIR" >/dev/null
"$REPO_ROOT/zig-out/bin/zmp" new "$APP_NAME" --app-id "$APP_ID" --port "$PORT"

echo "[3/5] Starting local HTTP server at 127.0.0.1:$PORT"
SERVE_DIR="$TMPDIR/www"
mkdir -p "$SERVE_DIR"
cat > "$SERVE_DIR/index.html" <<'HTML'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>ZMP E2E</title></head>
<body>
  <h1>ZMP E2E OK</h1>
  <p>Time: <span id="t"></span></p>
  <script>document.getElementById('t').textContent = new Date().toISOString();</script>
  <p>If you see this in the app, networking works.</p>
  <p>Served from host 127.0.0.1 over adb reverse.</p>
  <p>Port: 8085</p>
  </body>
</html>
HTML
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE_DIR" >/dev/null 2>&1 &
HTTP_PID=$!
cleanup() {
  kill "$HTTP_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "[4/5] Building and launching Android app (this may take a while)"
(
  cd "$TMPDIR/$APP_NAME"
  "$REPO_ROOT/zig-out/bin/zmp" dev android --port "$PORT"
)

echo "[5/5] Done. App should be open in the emulator/device."
echo "Temp project: $TMPDIR/$APP_NAME"
popd >/dev/null
