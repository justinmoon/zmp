ZMP (Zig Mobile Platform) — MVP (Android dev mode)

Quickstart

- Build the CLI: `zig build`
- Create a project: `zig-out/bin/zmp new demo --app-id com.example.demo --port 8085`
- Dev run (device/emulator required):
  - Start your Zig SSR locally on `127.0.0.1:8085`
  - `cd demo`
  - `../zig-out/bin/zmp dev android --port 8085`
    - Runs `adb reverse tcp:8085 tcp:8085`
    - Generates Gradle wrapper if missing (`gradle -p android wrapper`)
    - Builds/installs debug APK and launches the app

Prerequisites

- Android emulator or device connected
- Easiest path: Nix dev shell (installs adb/SDK/JDK/gradle)
  - Run `nix develop` (requires flakes enabled)
  - Re-run the quickstart commands inside the dev shell

Notes

- Dev mode points the Android WebView to `http://127.0.0.1:<PORT>`.
- Cleartext to 127.0.0.1 is allowed by `network_security_config.xml`.
- This MVP does not embed Zig code in the APK yet (release mode planned for M2).

Nix flake

- `flake.nix` provides:
  - `nix develop` shell with: Zig, JDK 17, Gradle, Android SDK (platform-tools, build-tools 34, platform android-34)
  - `nix build` to build the `zmp` binary (`result/bin/zmp`)
  - Environment variables: `ANDROID_HOME` / `ANDROID_SDK_ROOT` pre-set

Tips

- If running `zmp dev android` from repo root, pass `--project <dir>` or it will try to auto-detect a single child directory containing `zmp.toml`.
