# Plan: Restore in-app Zig web server with dual e2e coverage

## Goals
- Reinstate the Zig HTTP server inside the Android app (native mode) while keeping the simple FFI demo available for future debugging.
- Provide a single end-to-end script that can exercise both host-driven and native-driven flows and optionally run the Appium UI assertions.
- Update CI to run both permutations: host web server and native web server, each with UI verification.

## Investigation Tasks
1. **`getauxval` resolution**
   - Inspect the current minimal JNI library (`demo/native/ffi.zig`) compilation output with `nm -D` / `readelf -Ws` to confirm whether we define `getauxval`.
   - If the symbol remains unresolved, investigate Zig’s `std.os.linux.getauxval` usage; consider overriding via `pub export fn getauxval` (matching C signature) or, if needed, editing `std.os.linux.getauxval` for Android targets.
   - Evaluate alternative build flags (`-fstrip`, `-Dcpu=baseline`, `-Dsingle-threaded`) to minimize runtime feature probing. Keep notes on what resolves the load-time issue.

2. **Transport alternatives**
   - Explore whether the HTTP server can be swapped for WebView `postMessage`/`evaluateJavascript` bridge in the longer term.
   - Short term: ensure the HTTP server path is reliable. If the shim is straightforward and stable across API levels, document it and proceed; otherwise prototype a WebView messaging transport.

## Implementation Steps
1. **Reintroduce Zig HTTP server template**
   - Restore `writeNativeServer` to emit the counter HTTP server (listening on 127.0.0.1, serving the counter page).
   - Keep the FFI sample as an alternate template (e.g. `--template ffi`) while defaulting to the full server.
   - Update Kotlin scaffolding (`Native.kt`, `MainActivity.kt`) to call `Native.startServer(...)` and display the counter HTML in native mode.

2. **Consolidate scripts**
   - Merge `scripts/e2e.sh` and `scripts/test-ui.sh` into a single `scripts/test-e2e.sh` with flags:
     - `--mode host` / `--mode native`
     - `--with-ui` to run the Bun/Appium assertions.
   - Ensure the script can start/stop the host HTTP server (Python) when in host mode and skip it in native mode.

3. **Appium UI tests**
   - Extend `ui-tests/run.js` to accept `ZMP_EXPECT_TEXT` / selector overrides for each mode (host vs native counter HTML).
   - Add convenience wrappers or environment presets so the consolidated script can invoke the UI assertion twice (host/native).

4. **CI workflow**
   - Update `.github/workflows/ui-tests.yml` to run the new script in a matrix:
     - `scripts/test-e2e.sh --mode host --with-ui`
     - `scripts/test-e2e.sh --mode native --with-ui`
   - Ensure `APPIUM_HOME` and Bun dependencies work in the GitHub Action environment.

5. **Docs**
   - Refresh README to document the combined script (`scripts/test-e2e.sh`) and describe both modes.
   - Update `ui-tests/README.md` to reflect the new entry points and expectations.

## Testing Checklist
- Manually run:
  - `scripts/test-e2e.sh --mode host`
  - `scripts/test-e2e.sh --mode native`
  - `scripts/test-e2e.sh --mode host --with-ui`
  - `scripts/test-e2e.sh --mode native --with-ui`
- Verify both modes inside GitHub Actions using the updated workflow.

