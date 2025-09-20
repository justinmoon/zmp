#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export NATIVE=1

pushd "$ROOT" >/dev/null
scripts/e2e.sh
popd >/dev/null

pushd "$ROOT/ui-tests" >/dev/null
bun install
export APPIUM_HOME="${APPIUM_HOME:-$PWD/.appium}"
export ZMP_APP_PACKAGE="${ZMP_APP_PACKAGE:-com.example.demo}"
export ZMP_APP_ACTIVITY="${ZMP_APP_ACTIVITY:-.MainActivity}"
export ZMP_DEVICE_NAME="${ZMP_DEVICE_NAME:-Android Emulator}"
export ZMP_EXPECT_TEXT="${ZMP_EXPECT_TEXT:-Zig says: 42}"
export ZMP_EXPECT_SELECTOR="${ZMP_EXPECT_SELECTOR:-android=new UiSelector().textContains(\"Zig says\")}"
bun run test
popd >/dev/null
