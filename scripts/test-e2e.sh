#!/usr/bin/env bash
set -euo pipefail

MODE="host"
WITH_UI=0
PORT=8085
APP_NAME="${APP_NAME:-zmp_e2e_demo}"
APP_ID="${APP_ID:-com.example.zmpe2e}"
KEEP_TEMP=0

print_usage() {
  cat <<USAGE
Usage: scripts/test-e2e.sh [--mode host|native] [--with-ui] [--port <number>] [--keep-temp]

Environment variables:
  APP_NAME   (default: zmp_e2e_demo)
  APP_ID     (default: com.example.zmpe2e)
  PORT       (default: 8085)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --with-ui)
      WITH_UI=1
      shift
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "host" && "$MODE" != "native" ]]; then
  echo "error: --mode must be 'host' or 'native'" >&2
  exit 1
fi

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing '$1'" >&2
    exit 1
  }
}

if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  echo "error: must be run inside 'nix develop' (IN_NIX_SHELL not set)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

require zig
require adb

if [[ "$WITH_UI" -eq 1 ]]; then
  require bun
fi

TMPDIR="$(mktemp -d -t zmp-e2e.XXXXXX)"
PROJECT_DIR="$TMPDIR/$APP_NAME"
cleanup() {
  if [[ -n "${HOST_PID:-}" ]]; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP_TEMP" -eq 0 ]]; then
    rm -rf "$TMPDIR"
  else
    echo "temp preserved at: $TMPDIR"
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

echo "[1/6] Building zmp CLI"
zig build -Doptimize=ReleaseSafe

mkdir -p "$TMPDIR"
cd "$TMPDIR"

echo "[2/6] Creating project (template=server)"
"$REPO_ROOT/zig-out/bin/zmp" new "$APP_NAME" --app-id "$APP_ID" --port "$PORT" --template counter > /dev/null

if [[ "$MODE" == "host" ]]; then
  echo "[3/6] Starting host HTTP server on 127.0.0.1:$PORT"
  HOST_SERVER_SRC="$REPO_ROOT/scripts/host_server.zig"
  HOST_SERVER_BIN="$TMPDIR/host-server"
  zig build-exe "$HOST_SERVER_SRC" -OReleaseSafe -femit-bin="$HOST_SERVER_BIN"
  "$HOST_SERVER_BIN" "$PORT" >/dev/null 2>&1 &
  HOST_PID=$!
  sleep 1
else
  echo "[3/6] Native mode requested (no host HTTP server)"
fi

echo "[4/6] Building and launching Android app"
cd "$PROJECT_DIR"
DEV_ARGS=("$REPO_ROOT/zig-out/bin/zmp" "dev" "android" "--port" "$PORT")
if [[ "$MODE" == "native" ]]; then
  DEV_ARGS+=("--native")
fi
"${DEV_ARGS[@]}"

echo "[5/6] Waiting briefly for app to settle"
sleep 5

if [[ "$WITH_UI" -eq 1 ]]; then
  echo "[6/6] Running UI assertions"
  cd "$REPO_ROOT/ui-tests"
  bun install >/dev/null
  export APPIUM_HOME="${APPIUM_HOME:-$PWD/.appium}"
  export ZMP_APP_PACKAGE="$APP_ID"
  export ZMP_APP_ACTIVITY=".MainActivity"
  export ZMP_EXPECT_CONTEXT="web"
  export ZMP_WEB_SELECTOR="${ZMP_WEB_SELECTOR:-#count}"
  if [[ "$MODE" == "host" ]]; then
    export ZMP_WEB_EXPECT="${ZMP_WEB_EXPECT:-Count: 0}"
  else
    export ZMP_WEB_EXPECT="${ZMP_WEB_EXPECT:-Count: 0}"
  fi
  export ZMP_DEVICE_NAME="${ZMP_DEVICE_NAME:-Android Emulator}"
  adb shell am force-stop com.example.demo >/dev/null 2>&1 || true
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  bun run test
  cd "$REPO_ROOT"
else
  echo "[6/6] UI step skipped"
fi

echo "Done. Project directory: $PROJECT_DIR"
if [[ "$KEEP_TEMP" -eq 0 ]]; then
  echo "(temporary directory will be cleaned up)"
fi
