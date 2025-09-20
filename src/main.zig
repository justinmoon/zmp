const std = @import("std");
const builtin = @import("builtin");

const USAGE: []const u8 =
    "zmp - Zig Mobile Platform (M1 dev)\n"
    ++ "Usage:\n"
    ++ "  zmp new <name> [--app-id <id>] [--port <port>]\n"
    ++ "  zmp dev android [--project <path>] [--port <port>] [--native]\n"
    ++ "\n"
    ++ "Examples:\n"
    ++ "  zmp new myapp --app-id com.example.myapp --port 8085\n"
    ++ "  zmp dev android --project myapp --port 8085\n";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // program name
    const cmd = args.next() orelse return printUsage();
    if (std.mem.eql(u8, cmd, "new")) {
        return cmdNew(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        return cmdDev(allocator, &args);
    } else if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        return printUsage();
    } else {
        std.log.err("unknown command: {s}", .{cmd});
        return printUsage();
    }
}

fn printUsage() !void { std.debug.print("{s}", .{USAGE}); }

fn cmdNew(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const name = args.next() orelse {
        std.log.err("missing <name>", .{});
        return printUsage();
    };

    var app_id: []const u8 = "com.example.";
    const suffix = name;
    const app_id_buf = try std.fmt.allocPrint(allocator, "{s}{s}", .{ app_id, suffix });
    defer allocator.free(app_id_buf);
    app_id = app_id_buf;

    var port: u16 = 8085;

    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--app-id")) {
            if (args.next()) |val| app_id = val else break;
        } else if (std.mem.eql(u8, flag, "--port")) {
            if (args.next()) |val| port = std.fmt.parseUnsigned(u16, val, 10) catch port else break;
        } else {
            std.log.warn("unknown flag: {s}", .{flag});
        }
    }

    try createProject(allocator, name, app_id, port);
}

fn cmdDev(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    try ensureNixDevelop();
    const platform = args.next() orelse {
        std.log.err("missing platform (android)", .{});
        return printUsage();
    };
    if (!std.mem.eql(u8, platform, "android")) {
        std.log.err("unsupported platform: {s}", .{platform});
        return error.Unsupported;
    }

    var project_path: []const u8 = ".";
    var port: u16 = 8085;
    var use_native: bool = false;

    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--project")) {
            if (args.next()) |val| project_path = val else break;
        } else if (std.mem.eql(u8, flag, "--port")) {
            if (args.next()) |val| port = std.fmt.parseUnsigned(u16, val, 10) catch port else break;
        } else if (std.mem.eql(u8, flag, "--native")) {
            use_native = true;
        } else if (std.mem.eql(u8, flag, "-h") or std.mem.eql(u8, flag, "--help")) {
            return printUsage();
        } else {
            std.log.warn("unknown flag: {s}", .{flag});
        }
    }

    // Try to run dev. If project discovery fails, scan for a project.
    devAndroid(allocator, project_path, port, use_native) catch |err| {
        if (err == error.NotFound) {
            if (try discoverProjectPath(allocator, ".")) |auto_path| {
                defer allocator.free(auto_path);
                std.log.info("auto-detected project: {s}", .{auto_path});
                return devAndroid(allocator, auto_path, port, use_native);
            }
        }
        return err;
    };
}

fn ensureNixDevelop() !void {
    // Basic check for nix develop shell; direnv with use flake also sets this.
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, "IN_NIX_SHELL") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => {
            std.log.err("Not in nix develop shell. Run `nix develop` (or enable direnv).", .{});
            return error.AccessDenied;
        },
        else => return e,
    };
    defer std.heap.page_allocator.free(val);
}

fn createProject(allocator: std.mem.Allocator, name: []const u8, app_id: []const u8, port: u16) !void {
    const cwd = std.fs.cwd();
    try cwd.makeDir(name);
    var proj_dir = try cwd.openDir(name, .{ .iterate = true });
    defer proj_dir.close();

    const toml = try std.fmt.allocPrint(allocator,
        "[app]\nname=\"{s}\"\napp_id=\"{s}\"\nport={d}\n",
        .{ name, app_id, port },
    );
    defer allocator.free(toml);
    try writeFile(proj_dir, "zmp.toml", toml);

    try proj_dir.makeDir("android");
    var android_dir = try proj_dir.openDir("android", .{ .iterate = true });
    defer android_dir.close();

    try writeAndroidProject(allocator, android_dir, name, app_id, port);
    try writeNativeServer(allocator, proj_dir, app_id);

    std.log.info("Project created: {s}", .{name});
    std.log.info("Next: cd {s} && zmp dev android --port {d}", .{ name, port });
}

fn devAndroid(allocator: std.mem.Allocator, project_path: []const u8, port: u16, use_native: bool) !void {
    const cwd = std.fs.cwd();
    var proj = try cwd.openDir(project_path, .{ .iterate = true });
    defer proj.close();

    var app_id_buf: [512]u8 = undefined;
    const app_id = try readAppIdFromTomlOrGradle(&proj, &app_id_buf);

    // Ensure required tools exist
    ensureTool(&.{ "adb", "version" }, "adb (Android platform-tools)") catch {
        std.log.err("adb not found. Enter Nix dev shell: `nix develop`", .{});
        return error.FileNotFound;
    };
    ensureTool(&.{ "gradle", "-v" }, "gradle") catch {
        std.log.err("gradle not found. Enter Nix dev shell: `nix develop`", .{});
        return error.FileNotFound;
    };

    // If no connected devices, try to ensure an emulator exists and is running.
    if (try countConnectedDevices(allocator) == 0) {
        std.log.info("no devices found; preparing Android emulator", .{});
        // These are only needed if we must drive an emulator.
        ensureTool(&.{ "emulator", "-version" }, "Android Emulator") catch {
            std.log.err("emulator not found. Enter Nix dev shell: `nix develop`", .{});
            return error.FileNotFound;
        };
        ensureTool(&.{ "avdmanager", "list", "device" }, "avdmanager") catch {
            std.log.err("avdmanager not found. Enter Nix dev shell: `nix develop`", .{});
            return error.FileNotFound;
        };

        const avd_name = try ensureDefaultAvdExists(allocator);
        defer allocator.free(avd_name);
        try ensureEmulatorRunning(avd_name);
    }

    // Build JNI libs when requested via --native
    if (use_native and fileExists(proj, "native/server.zig")) {
        std.log.info("--native: building JNI libs", .{});
        // Ensure jniLibs dirs exist
        try runInDir(project_path, &.{ "bash", "-lc", "mkdir -p android/app/src/main/jniLibs/arm64-v8a android/app/src/main/jniLibs/x86_64" });
        // Build for arm64 (devices + Apple Silicon Emulator)
        try runInDir(project_path, &.{ "bash", "-lc",
            "zig build-lib native/server.zig -dynamic -fPIC -OReleaseSafe -target aarch64-linux-android -Dandroid_api_level=24 -femit-bin=android/app/src/main/jniLibs/arm64-v8a/libzmpserver.so" });
        // Build for x86_64 (Intel emulator)
        _ = runInDir(project_path, &.{ "bash", "-lc",
            "zig build-lib native/server.zig -dynamic -fPIC -OReleaseSafe -target x86_64-linux-android -Dandroid_api_level=24 -femit-bin=android/app/src/main/jniLibs/x86_64/libzmpserver.so" }) catch {};
    }

    var p1: [16]u8 = undefined;
    var p2: [16]u8 = undefined;
    if (!use_native) {
        const tcp1 = try std.fmt.bufPrint(&p1, "tcp:{d}", .{port});
        const tcp2 = try std.fmt.bufPrint(&p2, "tcp:{d}", .{port});
        try runCmd(&.{ "adb", "reverse", tcp1, tcp2 });
    }

    var has_wrapper = blk: {
        var android = try proj.openDir("android", .{ .iterate = true });
        defer android.close();
        break :blk fileExists(android, "gradlew");
    };

    if (!has_wrapper) {
        std.log.warn("Gradle wrapper not found. Generating with system gradle.", .{});
        try runInDir(project_path, &.{ "gradle", "-p", "android", "wrapper", "--gradle-version", "8.7" });
        has_wrapper = true;
    }

    if (has_wrapper) {
        if (use_native) {
            try runInDir(project_path, &.{ "bash", "-lc", "cd android && chmod +x ./gradlew && ./gradlew -PzmpNative=true assembleDebug installDebug" });
        } else {
            try runInDir(project_path, &.{ "bash", "-lc", "cd android && chmod +x ./gradlew && ./gradlew assembleDebug installDebug" });
        }
    } else {
        if (use_native) {
            try runInDir(project_path, &.{ "gradle", "-p", "android", "-PzmpNative=true", "assembleDebug", "installDebug" });
        } else {
            try runInDir(project_path, &.{ "gradle", "-p", "android", "assembleDebug", "installDebug" });
        }
    }

    var comp_buf: [512]u8 = undefined;
    const comp = try std.fmt.bufPrint(&comp_buf, "{s}/{s}.MainActivity", .{ app_id, app_id });
    try runCmd(&.{ "adb", "shell", "am", "start", "-n", comp });

    std.log.info("Launched {s} on device. WebView -> http://127.0.0.1:{d}", .{ app_id, port });
}

fn countConnectedDevices(allocator: std.mem.Allocator) !usize {
    const out = try captureStdout(allocator, &.{ "adb", "devices" });
    defer allocator.free(out);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\t") == null) continue;
        // status is after the last tab or space
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.endsWith(u8, trimmed, "\tdevice") or std.mem.endsWith(u8, trimmed, " device")) {
            count += 1;
        }
    }
    return count;
}

fn avdExists(allocator: std.mem.Allocator, name: []const u8) !bool {
    const out = try captureStdout(allocator, &.{ "emulator", "-list-avds" });
    defer allocator.free(out);
    // Quick substring check with line boundaries to reduce false positives.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn ensureDefaultAvdExists(allocator: std.mem.Allocator) ![]u8 {
    // Prefer API 34 google_apis images. Choose ABI based on host arch.
    const abi = if (builtin.cpu.arch == .aarch64) "arm64-v8a" else "x86_64";
    const pkg = if (std.mem.eql(u8, abi, "arm64-v8a"))
        "system-images;android-34;google_apis;arm64-v8a"
    else
        "system-images;android-34;google_apis;x86_64";

    const avd_name = try std.fmt.allocPrint(allocator, "zmp-api34-{s}", .{abi});

    // If an AVD with our name exists already, done.
    if (try avdExists(allocator, avd_name)) return avd_name;

    std.log.info("creating AVD '{s}' ({s})", .{ avd_name, pkg });

    // Try with a sensible hardware profile to avoid interactive prompts.
    var cmd_buf: [512]u8 = undefined;
    const base = try std.fmt.bufPrint(&cmd_buf, "avdmanager create avd -n {s} -k '{s}' --abi {s} --device pixel_5 --force", .{ avd_name, pkg, abi });
    runCmdSilently(&.{ "bash", "-lc", base }) catch {
        // Fallback to 'pixel' device name.
        const alt = try std.fmt.bufPrint(&cmd_buf, "avdmanager create avd -n {s} -k '{s}' --abi {s} --device pixel --force", .{ avd_name, pkg, abi });
        runCmdSilently(&.{ "bash", "-lc", alt }) catch {
            // Final fallback: no device profile, answer 'no' to interactive prompt via pipe.
            const piped = try std.fmt.allocPrint(allocator, "printf 'no\\n' | avdmanager create avd -n {s} -k '{s}' --abi {s} --force", .{ avd_name, pkg, abi });
            defer allocator.free(piped);
            try runCmd(&.{ "bash", "-lc", piped });
        };
    };
    return avd_name;
}

fn ensureEmulatorRunning(avd_name: []const u8) !void {
    // If any device is already present, no need to launch.
    if (try countConnectedDevices(std.heap.page_allocator) > 0) return;

    std.log.info("starting emulator '{s}'", .{avd_name});
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf,
        "nohup emulator -avd {s} -netdelay none -netspeed full -no-snapshot -no-boot-anim >/dev/null 2>&1 &",
        .{avd_name},
    );
    try runCmd(&.{ "bash", "-lc", cmd });

    // Wait for adb to see the device and the system to finish booting.
    _ = runCmd(&.{ "adb", "start-server" }) catch {};
    std.log.info("waiting for emulator to boot...", .{});
    try runCmd(&.{ "adb", "wait-for-device" });

    var tries: usize = 0;
    while (tries < 180) { // ~3 minutes
        const out = captureStdout(std.heap.page_allocator, &.{ "adb", "shell", "getprop", "sys.boot_completed" }) catch {
            _ = runCmdSilently(&.{ "bash", "-lc", "sleep 1" }) catch {};
            tries += 1;
            continue;
        };
        defer std.heap.page_allocator.free(out);
        const t = std.mem.trim(u8, out, " \t\r\n");
        if (t.len > 0 and std.mem.eql(u8, t, "1")) break;
        _ = runCmdSilently(&.{ "bash", "-lc", "sleep 1" }) catch {};
        tries += 1;
    }
}

fn readAppIdFromTomlOrGradle(proj: *std.fs.Dir, buf: []u8) ![]const u8 {
    if (proj.openFile("zmp.toml", .{})) |file| {
        defer file.close();
        var data = try file.readToEndAlloc(std.heap.page_allocator, 64 * 1024);
        defer std.heap.page_allocator.free(data);
        if (std.mem.indexOf(u8, data, "app_id=\"")) |start| {
            const off = start + "app_id=\"".len;
            if (std.mem.indexOfPos(u8, data, off, "\"")) |end| {
                const val = data[off..end];
                return std.fmt.bufPrint(buf, "{s}", .{val});
            }
        }
    } else |_| {}

    if (proj.openDir("android", .{ .iterate = true })) |dir_android| {
        var android = dir_android;
        defer android.close();
        var app = try android.openDir("app", .{ .iterate = true });
        defer app.close();
        var file = try app.openFile("build.gradle.kts", .{});
        defer file.close();
        var data = try file.readToEndAlloc(std.heap.page_allocator, 64 * 1024);
        defer std.heap.page_allocator.free(data);
        if (std.mem.indexOf(u8, data, "applicationId = \"")) |start| {
            const off = start + "applicationId = \"".len;
            if (std.mem.indexOfPos(u8, data, off, "\"")) |end| {
                const val = data[off..end];
                return std.fmt.bufPrint(buf, "{s}", .{val});
            }
        }
    } else |_| {}

    return error.NotFound;
}

fn discoverProjectPath(allocator: std.mem.Allocator, start_dir: []const u8) !?[]u8 {
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(start_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var found: ?[]u8 = null;
    while (try it.next()) |ent| {
        if (ent.kind != .directory) continue;
        if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        var sub = try dir.openDir(ent.name, .{ .iterate = true });
        defer sub.close();
        // Check for zmp.toml
        if (sub.access("zmp.toml", .{})) {
            if (found != null) return null; // multiple; ambiguous
            found = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ start_dir, ent.name });
            continue;
        } else |_| {}
        // Check for android/app/build.gradle.kts
        var android_dir = sub.openDir("android", .{ .iterate = true }) catch continue;
        defer android_dir.close();
        var app_dir_maybe = android_dir.openDir("app", .{ .iterate = true }) catch null;
        if (app_dir_maybe) |*app_dir| {
            defer app_dir.close();
            var has_build = true;
            app_dir.access("build.gradle.kts", .{}) catch { has_build = false; };
            if (has_build) {
                if (found != null) return null; // multiple; ambiguous
                found = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ start_dir, ent.name });
            }
        }
    }
    return found;
}

fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

fn runCmd(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

fn runInDir(dir: []const u8, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.cwd = dir;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

fn runCmdSilently(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

fn captureStdout(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
    return out;
}

fn ensureTool(argv: []const []const u8, label: []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("required tool missing: {s}", .{label});
            return e;
        },
        else => return e,
    };
    const term = try child.wait();
    switch (term) {
        .Exited => |_| {},
        else => return error.SubprocessFailed,
    }
}

fn writeFile(dir: std.fs.Dir, path: []const u8, contents: []const u8) !void {
    var file = try dir.createFile(path, .{ .read = true, .truncate = true, .exclusive = false });
    defer file.close();
    try file.writeAll(contents);
}

fn writeAndroidProject(allocator: std.mem.Allocator, android_dir: std.fs.Dir, name: []const u8, app_id: []const u8, port: u16) !void {
    // settings.gradle.kts
    var s_buf = std.array_list.Managed(u8).init(allocator);
    defer s_buf.deinit();
    var sw = s_buf.writer();
    try sw.writeAll(
        "pluginManagement {\n" ++
        "  repositories {\n" ++
        "    gradlePluginPortal()\n" ++
        "    google()\n" ++
        "    mavenCentral()\n" ++
        "  }\n" ++
        "}\n" ++
        "dependencyResolutionManagement {\n" ++
        "  repositories {\n" ++
        "    google()\n" ++
        "    mavenCentral()\n" ++
        "  }\n" ++
        "}\n" ++
        "rootProject.name = \"");
    try sw.print("{s}", .{name});
    try sw.writeAll("\"\ninclude(\":app\")\n");
    const settings_txt = try s_buf.toOwnedSlice();
    defer allocator.free(settings_txt);
    try writeFile(android_dir, "settings.gradle.kts", settings_txt);

    const root_build =
        "plugins {\n" ++
        "  id(\"com.android.application\") version \"8.4.0\" apply false\n" ++
        "  id(\"org.jetbrains.kotlin.android\") version \"1.9.23\" apply false\n" ++
        "}\n";
    try writeFile(android_dir, "build.gradle.kts", root_build);

    const gradle_props =
        "org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8\n" ++
        "android.useAndroidX=true\n" ++
        "kotlin.code.style=official\n";
    try writeFile(android_dir, "gradle.properties", gradle_props);

    try android_dir.makeDir("app");
    var app_dir = try android_dir.openDir("app", .{ .iterate = true });
    defer app_dir.close();

    // app/build.gradle.kts
    var b_buf = std.array_list.Managed(u8).init(allocator);
    defer b_buf.deinit();
    var bw = b_buf.writer();
    try bw.writeAll(
        "plugins {\n  id(\"com.android.application\")\n  id(\"org.jetbrains.kotlin.android\")\n}\n\n" ++
        "val zmpNative = (project.findProperty(\"zmpNative\") as String?)?.toBoolean() ?: false\n" ++
        "android {\n  namespace = \"");
    try bw.print("{s}", .{app_id});
    try bw.writeAll("\"\n  compileSdk = 34\n  defaultConfig {\n    applicationId = \"");
    try bw.print("{s}", .{app_id});
    try bw.writeAll("\"\n    minSdk = 24\n    targetSdk = 34\n    versionCode = 1\n    versionName = \"1.0\"\n    buildConfigField(\"int\", \"DEV_SERVER_PORT\", \"");
    try bw.print("{d}", .{port});
    try bw.writeAll("\")\n    buildConfigField(\"boolean\", \"DEV_NATIVE\", zmpNative.toString())\n  }\n  buildFeatures {\n    buildConfig = true\n  }\n  buildTypes {\n    getByName(\"release\") { isMinifyEnabled = false }\n  }\n  compileOptions {\n    sourceCompatibility = JavaVersion.VERSION_17\n    targetCompatibility = JavaVersion.VERSION_17\n  }\n  kotlinOptions { jvmTarget = \"17\" }\n}\n\n");
    try bw.writeAll(
        "dependencies {\n  implementation(\"androidx.appcompat:appcompat:1.7.0\")\n  implementation(\"androidx.webkit:webkit:1.11.0\")\n  implementation(\"androidx.activity:activity-ktx:1.9.2\")\n}\n");
    const app_build = try b_buf.toOwnedSlice();
    defer allocator.free(app_build);
    try writeFile(app_dir, "build.gradle.kts", app_build);

    try app_dir.makeDir("src");
    var src_dir = try app_dir.openDir("src", .{ .iterate = true });
    defer src_dir.close();
    try src_dir.makeDir("main");
    var main_dir = try app_dir.openDir("src/main", .{ .iterate = true });
    defer main_dir.close();

    // AndroidManifest.xml
    var m_buf = std.array_list.Managed(u8).init(allocator);
    defer m_buf.deinit();
    var mw = m_buf.writer();
    try mw.writeAll(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n  <uses-permission android:name=\"android.permission.INTERNET\"/>\n  <application android:label=\"@string/app_name\" android:icon=\"@android:drawable/ic_menu_view\" android:theme=\"@style/AppTheme\" android:networkSecurityConfig=\"@xml/network_security_config\">\n    <activity android:name=\"");
    try mw.print("{s}", .{app_id});
    try mw.writeAll(".MainActivity\" android:exported=\"true\" android:configChanges=\"orientation|screenLayout|screenSize|keyboardHidden\">\n      <intent-filter>\n        <action android:name=\"android.intent.action.MAIN\"/>\n        <category android:name=\"android.intent.category.LAUNCHER\"/>\n      </intent-filter>\n    </activity>\n  </application>\n</manifest>\n");
    const manifest = try m_buf.toOwnedSlice();
    defer allocator.free(manifest);
    try writeFile(main_dir, "AndroidManifest.xml", manifest);

    try main_dir.makeDir("res");
    var res_dir = try app_dir.openDir("src/main/res", .{ .iterate = true });
    defer res_dir.close();
    try res_dir.makeDir("values");
    var values_dir = try app_dir.openDir("src/main/res/values", .{ .iterate = true });
    defer values_dir.close();
    const strings_xml = try std.fmt.allocPrint(allocator, "<resources>\n  <string name=\"app_name\">{s}</string>\n</resources>\n", .{ name });
    defer allocator.free(strings_xml);
    try writeFile(values_dir, "strings.xml", strings_xml);
    const styles_xml = "<resources>\n  <style name=\"AppTheme\" parent=\"Theme.AppCompat.Light.NoActionBar\"/>\n</resources>\n";
    try writeFile(values_dir, "styles.xml", styles_xml);

    try res_dir.makeDir("xml");
    var xml_dir = try app_dir.openDir("src/main/res/xml", .{ .iterate = true });
    defer xml_dir.close();
    const netsec = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<network-security-config>\n  <domain-config cleartextTrafficPermitted=\"true\">\n    <domain includeSubdomains=\"true\">127.0.0.1</domain>\n  </domain-config>\n</network-security-config>\n";
    try writeFile(xml_dir, "network_security_config.xml", netsec);

    try main_dir.makeDir("kotlin");
    var kotlin_dir = try app_dir.openDir("src/main/kotlin", .{ .iterate = true });
    defer kotlin_dir.close();

    try makeKotlinPkgDirs(allocator, app_dir, "src/main/kotlin", app_id);
    const pkg_path = try joinKotlinPkgPath(allocator, "src/main/kotlin", app_id);
    defer allocator.free(pkg_path);
    var pkg_dir = try app_dir.openDir(pkg_path, .{ .iterate = true });
    defer pkg_dir.close();

    var k_buf = std.array_list.Managed(u8).init(allocator);
    defer k_buf.deinit();
    var kw = k_buf.writer();
    try kw.writeAll("package ");
    try kw.print("{s}", .{app_id});
    try kw.writeAll("\n\nimport android.os.Bundle\nimport android.webkit.WebView\nimport android.webkit.WebViewClient\nimport androidx.appcompat.app.AppCompatActivity\n\nclass MainActivity : AppCompatActivity() {\n  override fun onCreate(savedInstanceState: Bundle?) {\n    super.onCreate(savedInstanceState)\n    if (BuildConfig.DEV_NATIVE) {\n      Native.startServer(BuildConfig.DEV_SERVER_PORT)\n    }\n    val webView = WebView(this)\n    if (BuildConfig.DEBUG) {\n      WebView.setWebContentsDebuggingEnabled(true)\n    }\n    val s = webView.settings\n    s.javaScriptEnabled = true\n    s.domStorageEnabled = true\n    webView.webViewClient = WebViewClient()\n    setContentView(webView)\n    webView.loadUrl(\"http://127.0.0.1:${BuildConfig.DEV_SERVER_PORT}/\")\n  }\n}\n");
    const main_kt = try k_buf.toOwnedSlice();
    defer allocator.free(main_kt);
    try writeFile(pkg_dir, "MainActivity.kt", main_kt);

    // Write Native.kt shim
    var n_buf = std.array_list.Managed(u8).init(allocator);
    defer n_buf.deinit();
    var nw = n_buf.writer();
    try nw.writeAll("package ");
    try nw.print("{s}", .{app_id});
    try nw.writeAll("\n\nobject Native {\n  init { System.loadLibrary(\"zmpserver\") }\n  @JvmStatic external fun startServer(port: Int)\n}\n");
    const native_kt = try n_buf.toOwnedSlice();
    defer allocator.free(native_kt);
    try writeFile(pkg_dir, "Native.kt", native_kt);
}

fn makeKotlinPkgDirs(allocator: std.mem.Allocator, base_dir: std.fs.Dir, base: []const u8, pkg: []const u8) !void {
    var parts = std.mem.splitScalar(u8, pkg, '.');
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice(base);
    while (parts.next()) |seg| {
        try buf.append('/');
        try buf.appendSlice(seg);
        const p = buf.items;
        _ = base_dir.makeDir(p) catch {};
    }
}

fn joinKotlinPkgPath(allocator: std.mem.Allocator, base: []const u8, pkg: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, pkg, '.');
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice(base);
    while (parts.next()) |seg| {
        try buf.append('/');
        try buf.appendSlice(seg);
    }
    return try buf.toOwnedSlice();
}

fn writeNativeServer(allocator: std.mem.Allocator, proj_dir: std.fs.Dir, app_id: []const u8) !void {
    _ = proj_dir.makeDir("native") catch {};
    var native_dir = try proj_dir.openDir("native", .{ .iterate = true });
    defer native_dir.close();

    var underscored = std.array_list.Managed(u8).init(allocator);
    defer underscored.deinit();
    for (app_id) |c| try underscored.append(if (c == '.') '_' else c);
    const jni_sym = try std.fmt.allocPrint(allocator, "Java_{s}_Native_startServer", .{underscored.items});
    defer allocator.free(jni_sym);

    var sbuf = std.array_list.Managed(u8).init(allocator);
    defer sbuf.deinit();
    var w = sbuf.writer();
    try w.writeAll("const std = @import(\"std\");\n\n");
    try w.writeAll("var started = std.atomic.Value(u8).init(0);\n");
    try w.writeAll("var counter = std.atomic.Value(u64).init(0);\n\n");
    try w.writeAll("fn serverMain(port: u16) !void {\n");
    try w.writeAll("    const addr = try std.net.Address.parseIp4(\"127.0.0.1\", port);\n");
    try w.writeAll("    var server = try std.net.Address.listen(addr, .{});\n");
    try w.writeAll("    defer server.deinit();\n");
    try w.writeAll("    while (true) {\n");
    try w.writeAll("        const conn = try server.accept();\n");
    try w.writeAll("        const t = try std.Thread.spawn(.{}, handleConn, .{conn});\n");
    try w.writeAll("        t.detach();\n");
    try w.writeAll("    }\n");
    try w.writeAll("}\n\n");
    try w.writeAll("fn handleConn(conn: std.net.Server.Connection) !void {\n");
    try w.writeAll("    defer conn.stream.close();\n");
    try w.writeAll("    var buf: [4096]u8 = undefined;\n");
    try w.writeAll("    const n = conn.stream.read(&buf) catch return;\n");
    try w.writeAll("    if (n == 0) return;\n");
    try w.writeAll("    const req = buf[0..n];\n");
    try w.writeAll("    var path: []const u8 = \"/\";\n");
    try w.writeAll("    if (std.mem.indexOf(u8, req, \" \")) |sp1| {\n");
    try w.writeAll("        const off = sp1 + 1;\n");
    try w.writeAll("        if (std.mem.indexOfPos(u8, req, off, \" \")) |sp2| {\n");
    try w.writeAll("            path = req[off..sp2];\n");
    try w.writeAll("        }\n");
    try w.writeAll("    }\n");
    try w.writeAll("    if (std.mem.eql(u8, path, \"/inc\")) {\n");
    try w.writeAll("        _ = counter.fetchAdd(1, .monotonic);\n");
    try w.writeAll("        try writeHtml(conn);\n");
    try w.writeAll("    } else {\n");
    try w.writeAll("        try writeHtml(conn);\n");
    try w.writeAll("    }\n");
    try w.writeAll("}\n\n");
    try w.writeAll("fn writeHtml(conn: std.net.Server.Connection) !void {\n");
    try w.writeAll("    const val = counter.load(.monotonic);\n");
    try w.writeAll("    const body = std.fmt.allocPrint(std.heap.page_allocator, \"<!doctype html>\\n<html><head><meta charset=\\\"utf-8\\\"><title>ZMP Counter</title></head>\\n<body>\\n<h1>ZMP Counter</h1>\\n<p>Count: {d}</p>\\n<p><a href=\\\"/inc\\\">Increment</a></p>\\n</body></html>\", .{val}) catch return;\n");
    try w.writeAll("    defer std.heap.page_allocator.free(body);\n");
    try w.writeAll("    const resp = std.fmt.allocPrint(std.heap.page_allocator, \"HTTP/1.1 200 OK\\r\\nContent-Type: text/html; charset=utf-8\\r\\nContent-Length: {d}\\r\\nConnection: close\\r\\n\\r\\n{s}\", .{ body.len, body }) catch return;\n");
    try w.writeAll("    defer std.heap.page_allocator.free(resp);\n");
    try w.writeAll("    _ = conn.stream.writeAll(resp) catch return;\n");
    try w.writeAll("}\n\n");
    try w.writeAll("export fn ");
    try w.writeAll(jni_sym);
    try w.writeAll("(env: ?*anyopaque, clazz: ?*anyopaque, port: c_int) callconv(.c) void {\n");
    try w.writeAll("    _ = env; _ = clazz;\n");
    try w.writeAll("    const prev = started.swap(1, .seq_cst);\n");
    try w.writeAll("    if (prev == 1) return; // already started\n");
    try w.writeAll("    const t = std.Thread.spawn(.{}, start, .{@as(u16, @intCast(port))}) catch return;\n");
    try w.writeAll("    t.detach();\n");
    try w.writeAll("}\n\n");
    try w.writeAll("fn start(port: u16) void {\n");
    try w.writeAll("    serverMain(port) catch {};\n");
    try w.writeAll("}\n");

    const server_zig = try sbuf.toOwnedSlice();
    defer allocator.free(server_zig);
    try writeFile(native_dir, "server.zig", server_zig);
}
