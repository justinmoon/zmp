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
  - Native FFI sample (no host server):
    - `cd demo`
    - `../zig-out/bin/zmp dev android --port 8085 --native`
      - Compiles `native/ffi.zig` to JNI libs for arm64/x86_64
      - Installs the demo app. The app calls `Native.getNumber()` (implemented in Zig) and displays the result.

Prerequisites

- Android emulator or device connected
- Easiest path: Nix dev shell (installs adb/SDK/JDK/gradle)
  - Run `nix develop` (requires flakes enabled)
  - Re-run the quickstart commands inside the dev shell

Bundled demo project

- `demo/` contains a vendored Android project ready to run without `zmp`:
  - `demo/native/ffi.zig` — exports `Java_*_Native_getNumber` returning `42` (demonstrates FFI).
  - `demo/build_native.sh` — builds `libzmpserver.so` for `arm64-v8a` and `x86_64` using Zig (no NDK toolchain required).
  - `demo/android` — standard Gradle project; run `./gradlew :app:installDebug` after building the JNI libs.
- You can iterate on the demo by:
  1. `cd demo`
  2. `./build_native.sh`
  3. `./android/gradlew installDebug`

Notes

- Dev mode points the Android WebView to `http://127.0.0.1:<PORT>`; the native FFI sample shows how to call into Zig without the host server.
- Cleartext to 127.0.0.1 is allowed by `network_security_config.xml`.
- Native mode currently exposes a stub `startServer` for future work; it simply does nothing in the FFI sample.

Nix flake

- `flake.nix` provides:
  - `nix develop` shell with: Zig, JDK 17, Gradle, Android SDK (platform-tools, build-tools 34, platform android-34)
  - `nix build` to build the `zmp` binary (`result/bin/zmp`)
  - Environment variables: `ANDROID_HOME` / `ANDROID_SDK_ROOT` pre-set

Tips

- If running `zmp dev android` from repo root, pass `--project <dir>` or it will try to auto-detect a single child directory containing `zmp.toml`.
