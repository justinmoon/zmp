# ZMP UI Tests

End-to-end UI checks for the sample Android app using Appium + WebdriverIO.

## Prerequisites

- Android emulator or device running and visible via `adb devices`
- Appium binary available (installed via `bun install` as part of the dependency set)
- Appium UiAutomator2 driver installed once via `npx appium driver install uiautomator2@2.27.0`
- `bun` available (`brew install bun` or see https://bun.sh)
- The demo app installed (e.g. run `../scripts/e2e.sh` or `../zig-out/bin/zmp dev android --project demo --port 8085 --native`)

## Install dependencies

```bash
cd ui-tests
bun install
```

## Run the test suite

```bash
# from repo root (adjust package/activity if different)
cd ui-tests
ZMP_APP_PACKAGE=com.example.demo bun run test
```

### One-shot end-to-end run

```bash
scripts/test-ui.sh
```

Run it from the repo root inside `nix develop`; it builds the CLI, installs the sample app in native mode, and triggers the UI assertion automatically.

Environment variables:

- `ZMP_APP_PACKAGE` (default `com.example.demo`)
- `ZMP_APP_ACTIVITY` (default `.MainActivity`)
- `ZMP_DEVICE_NAME` (default `Android Emulator`)
- `ZMP_EXPECT_TEXT` (default `Zig says: 42`)
- `ZMP_EXPECT_SELECTOR` (default `android=new UiSelector().textContains("Zig says")`)

## Typical CI flow

1. Boot emulator (headless) and wait for boot
2. `scripts/e2e.sh` (or `zig-out/bin/zmp ... --native`) to build/install the app
3. `cd ui-tests && bun install`
4. `ZMP_APP_PACKAGE=... bun run test`

This script spawns Appium, connects via WebdriverIO, and asserts that the TextView rendered by the app matches `Zig says: 42` coming from the Zig FFI call.
