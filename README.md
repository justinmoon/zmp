ZMP (Zig Mobile Platform) — MVP (Android dev mode)

Quickstart

- Build the CLI: `zig build`
- Create a project: `zig-out/bin/zmp new demo --app-id com.example.demo --port 8085`
- Dev run (device/emulator required):
  - Host-driven webview (default):
    - Start your Zig SSR locally on `127.0.0.1:8085`
    - `cd demo`
    - `../zig-out/bin/zmp dev android --port 8085`
      - Runs `adb reverse tcp:8085 tcp:8085`
      - Generates Gradle wrapper if missing (`gradle -p android wrapper`)
      - Builds/installs debug APK and launches the app
  - Native counter server (runs inside the app):
    - `cd demo`
    - `../zig-out/bin/zmp dev android --port 8085 --native`
      - Compiles the bundled JNI sources for arm64/x86_64
      - Starts the embedded Zig HTTP server and points the WebView at it.

Prerequisites

- Android emulator or device connected
- Easiest path: Nix dev shell (installs adb/SDK/JDK/gradle)
  - Run `nix develop` (requires flakes enabled)
  - Re-run the quickstart commands inside the dev shell

Bundled demo project

- `demo/` contains a vendored Android project ready to run without `zmp`:
  - `demo/native/ffi.zig` — JNI entry points (including `getauxval`) used by the counter server.
  - `demo/native/server.zig` — Zig HTTP counter service exposed to Android via JNI.
  - `demo/native/static/index.html` — HTML template used by the counter UI.
  - `demo/android` — standard Gradle project; run `../zig-out/bin/zmp dev android --project demo --port 8085 --native` to rebuild and install.
- You can iterate on the demo by:
  1. `cd demo`
  2. `../zig-out/bin/zmp dev android --port 8085 --native`

Notes

- Dev mode points the Android WebView to `http://127.0.0.1:<PORT>`; use `--native` to run the embedded Zig server on the device.
- Cleartext to 127.0.0.1 is allowed by `network_security_config.xml`.

- UI automation (Appium + WebdriverIO)

- `ui-tests/` contains headless UI checks using Bun + WebdriverIO + Appium.
- Typical flow:
  1. Start an emulator (headless) and wait for boot.
  2. Build/install the app (e.g. `scripts/test-e2e.sh --mode host` or `../zig-out/bin/zmp dev ... --native`).
  3. `cd ui-tests && bun install` (first time).
  4. `ZMP_APP_PACKAGE=com.example.demo bun run test`.
- `scripts/test-e2e.sh --mode native --with-ui` runs the entire flow end-to-end (project scaffolding, build/install, Appium assertion). Run from repo root inside `nix develop`.
- The UI harness switches into the WebView context and asserts the counter reads `Count: 0`. See `ui-tests/README.md` for configuration options.

Nix flake

- `flake.nix` provides:
  - `nix develop` shell with: Zig, JDK 17, Gradle, Android SDK (platform-tools, build-tools 34, platform android-34)
  - `nix build` to build the `zmp` binary (`result/bin/zmp`)
  - Environment variables: `ANDROID_HOME` / `ANDROID_SDK_ROOT` pre-set

Tips

- If running `zmp dev android` from repo root, pass `--project <dir>` or it will try to auto-detect a single child directory containing `zmp.toml`.
