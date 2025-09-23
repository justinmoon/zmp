# ZMP UI Tests

End-to-end UI checks for the sample Android app using Appium + WebdriverIO.

## Prerequisites

- Android emulator or device running and visible via `adb devices`
- Appium binary available (installed via `bun install` as part of the dependency set)
- Appium UiAutomator2 driver installed once via `npx appium driver install uiautomator2@2.27.0`
- `bun` available (`brew install bun` or see https://bun.sh)
- The demo app installed (e.g. run `../scripts/test-e2e.sh --mode native` or `../zig-out/bin/zmp dev android --project demo --port 8085 --native`)

## Install dependencies

```bash
cd ui-tests
bun install
```

## Run the test suite

```bash
# from repo root (adjust package/activity if different)
cd ui-tests
ZMP_APP_PACKAGE=com.example.demo \
ZMP_EXPECT_CONTEXT=web \
ZMP_WEB_SELECTOR='#count' \
ZMP_WEB_EXPECT='Count: 0' \
bun run test
```

### One-shot end-to-end run

```bash
scripts/test-e2e.sh --mode native
```

Run it from the repo root inside `nix develop`; it scaffolds a fresh project, installs the sample app in native mode, and drives the WebView assertions automatically. Add `--skip-ui-tests` if you only need the build/install smoke pass.

Environment variables:

- `ZMP_APP_PACKAGE` (default `com.example.demo`)
- `ZMP_APP_ACTIVITY` (default `.MainActivity`)
- `ZMP_DEVICE_NAME` (default `Android Emulator`)
- `ZMP_EXPECT_CONTEXT` (`web` or `native`, default `web`)
- `ZMP_WEB_SELECTOR` (default `#count`)
- `ZMP_WEB_EXPECT` (default `Count: 0`)
- `ZMP_NATIVE_SELECTOR` / `ZMP_EXPECT_SELECTOR` (fallback for native assertions)
- `ZMP_NATIVE_EXPECT` / `ZMP_EXPECT_TEXT` (fallback for native assertions)

## Typical CI flow

1. Boot emulator (headless) and wait for boot
2. `scripts/test-e2e.sh --mode native`
3. `cd ui-tests && bun install`
4. `ZMP_APP_PACKAGE=... bun run test`

The harness spawns Appium, connects via WebdriverIO, switches into the WebView context, validates the initial count, clicks the increment and decrement buttons, and confirms the counter updates after each interaction.
