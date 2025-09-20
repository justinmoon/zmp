const std = @import("std");
const builtin = @import("builtin");

const Template = enum {
    counter,
    ffi,
};

const USAGE: []const u8 =
    "zmp - Zig Mobile Platform (M1 dev)\n" ++ "Usage:\n" ++ "  zmp new <name> [--app-id <id>] [--port <port>] [--template <counter|ffi>]\n" ++ "  zmp dev android [--project <path>] [--port <port>] [--native]\n" ++ "\n" ++ "Examples:\n" ++ "  zmp new myapp --app-id com.example.myapp --port 8085\n" ++ "  zmp dev android --project myapp --port 8085\n";

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

fn printUsage() !void {
    std.debug.print("{s}", .{USAGE});
}

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
    var template: Template = .counter;

    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--app-id")) {
            if (args.next()) |val| app_id = val else break;
        } else if (std.mem.eql(u8, flag, "--port")) {
            if (args.next()) |val| port = std.fmt.parseUnsigned(u16, val, 10) catch port else break;
        } else if (std.mem.eql(u8, flag, "--template")) {
            if (args.next()) |val| {
                template = parseTemplate(val) catch |err| switch (err) {
                    error.UnknownTemplate => {
                        std.log.err("unknown template: {s}", .{val});
                        return printUsage();
                    },
                };
            } else break;
        } else {
            std.log.warn("unknown flag: {s}", .{flag});
        }
    }

    try createProject(allocator, name, app_id, port, template);
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

fn parseTemplate(value: []const u8) error{UnknownTemplate}!Template {
    if (std.mem.eql(u8, value, "counter")) return .counter;
    if (std.mem.eql(u8, value, "ffi")) return .ffi;
    return error.UnknownTemplate;
}

fn createProject(allocator: std.mem.Allocator, name: []const u8, app_id: []const u8, port: u16, template: Template) !void {
    const cwd = std.fs.cwd();
    try cwd.makeDir(name);
    var proj_dir = try cwd.openDir(name, .{ .iterate = true });
    defer proj_dir.close();

    const toml = try std.fmt.allocPrint(
        allocator,
        "[app]\nname=\"{s}\"\napp_id=\"{s}\"\nport={d}\ntemplate=\"{s}\"\n",
        .{ name, app_id, port, templateName(template) },
    );
    defer allocator.free(toml);
    try writeFile(proj_dir, "zmp.toml", toml);

    const templates_root = try getTemplatesRoot(allocator);
    defer allocator.free(templates_root);

    const project_android_path = try std.fs.path.join(allocator, &.{ name, "android" });
    defer allocator.free(project_android_path);

    const android_template = try std.fs.path.join(allocator, &.{ templates_root, "android" });
    defer allocator.free(android_template);
    try copyTemplateTree(allocator, android_template, project_android_path);

    if (template == .ffi) {
        const override_path = try std.fs.path.join(allocator, &.{ templates_root, "ffi", "android-overrides" });
        defer allocator.free(override_path);
        try copyTemplateTree(allocator, override_path, project_android_path);
    }

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);
    const jni_prefix = try packageToJniPrefix(allocator, app_id);
    defer allocator.free(jni_prefix);

    const replacements = [_]Replacement{
        .{ .needle = "__APP_NAME__", .value = name },
        .{ .needle = "__APP_ID__", .value = app_id },
        .{ .needle = "__DEV_SERVER_PORT__", .value = port_str },
        .{ .needle = "__JNI_PREFIX__", .value = jni_prefix },
    };

    try replacePlaceholdersInFile(allocator, project_android_path, "settings.gradle.kts", &replacements);
    try replacePlaceholdersInFile(allocator, project_android_path, "app/build.gradle.kts", &replacements);
    try replacePlaceholdersInFile(allocator, project_android_path, "app/src/main/AndroidManifest.xml", &replacements);
    try replacePlaceholdersInFile(allocator, project_android_path, "app/src/main/res/values/strings.xml", &replacements);
    try replacePlaceholdersInFile(allocator, project_android_path, "app/src/main/kotlin/com/example/templateapp/MainActivity.kt", &replacements);
    try replacePlaceholdersInFile(allocator, project_android_path, "app/src/main/kotlin/com/example/templateapp/Native.kt", &replacements);

    try installNativeTemplate(allocator, templates_root, name, template, &replacements);

    try relocateKotlinPackage(allocator, project_android_path, "com.example.templateapp", app_id);

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

    const template = readTemplateFromConfig(&proj);

    // Build JNI libs when requested via --native
    if (use_native) {
        const templates_root = try getTemplatesRoot(allocator);
        defer allocator.free(templates_root);
        const jni_prefix = try packageToJniPrefix(allocator, app_id);
        defer allocator.free(jni_prefix);
        const native_replacements = [_]Replacement{
            .{ .needle = "__APP_ID__", .value = app_id },
            .{ .needle = "__JNI_PREFIX__", .value = jni_prefix },
        };

        switch (template) {
            .counter => {
                if (!fileExists(proj, "native/ffi.zig") or !fileExists(proj, "native/server.zig")) {
                    std.log.warn("--native: scaffolding counter native sources", .{});
                    try installNativeTemplate(allocator, templates_root, project_path, template, &native_replacements);
                }
            },
            .ffi => {
                if (!fileExists(proj, "native/ffi.zig")) {
                    std.log.warn("--native: scaffolding ffi native sources", .{});
                    try installNativeTemplate(allocator, templates_root, project_path, template, &native_replacements);
                }
            },
        }
        std.log.info("--native: building JNI libs", .{});
        // Ensure jniLibs dirs exist
        try runInDir(project_path, &.{ "bash", "-lc", "mkdir -p android/app/src/main/jniLibs/arm64-v8a android/app/src/main/jniLibs/x86_64" });
        // Build for arm64 (devices + Apple Silicon Emulator)
        try runInDir(project_path, &.{ "bash", "-lc", "zig build-lib native/ffi.zig -dynamic -fPIC -OReleaseSafe -target aarch64-linux-android -Dandroid_api_level=24 -femit-bin=android/app/src/main/jniLibs/arm64-v8a/libzmpserver.so -Inative" });
        // Build for x86_64 (Intel emulator)
        _ = runInDir(project_path, &.{ "bash", "-lc", "zig build-lib native/ffi.zig -dynamic -fPIC -OReleaseSafe -target x86_64-linux-android -Dandroid_api_level=24 -femit-bin=android/app/src/main/jniLibs/x86_64/libzmpserver.so -Inative" }) catch {};
    }

    _ = runCmdSilently(&.{ "adb", "shell", "am", "force-stop", app_id }) catch {};

    var p1: [16]u8 = undefined;
    const tcp_remove = try std.fmt.bufPrint(&p1, "tcp:{d}", .{port});
    _ = runCmdSilently(&.{ "adb", "reverse", "--remove", tcp_remove }) catch {};

    var p2: [16]u8 = undefined;
    if (!use_native) {
        const tcp_dst = try std.fmt.bufPrint(&p2, "tcp:{d}", .{port});
        try runCmd(&.{ "adb", "reverse", tcp_remove, tcp_dst });
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
    const cmd = try std.fmt.bufPrint(
        &cmd_buf,
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

fn readTemplateFromConfig(proj: *std.fs.Dir) Template {
    if (proj.openFile("zmp.toml", .{})) |file| {
        defer file.close();
        const data = file.readToEndAlloc(std.heap.page_allocator, 64 * 1024) catch return .counter;
        defer std.heap.page_allocator.free(data);
        if (std.mem.indexOf(u8, data, "template=\"")) |start| {
            const off = start + "template=\"".len;
            if (std.mem.indexOfPos(u8, data, off, "\"")) |end| {
                const val = data[off..end];
                return parseTemplate(val) catch .counter;
            }
        }
    } else |_| {}
    return .counter;
}

const Replacement = struct {
    needle: []const u8,
    value: []const u8,
};

fn templateName(template: Template) []const u8 {
    return switch (template) {
        .counter => "counter",
        .ffi => "ffi",
    };
}

fn getTemplatesRoot(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ exe_dir, "..", "..", "templates" });
}

fn copyTemplateTree(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    try std.fs.cwd().makePath(dst_path);

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(child_src);
        const child_dst = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
        defer allocator.free(child_dst);
        switch (entry.kind) {
            .directory => try copyTemplateTree(allocator, child_src, child_dst),
            .file => {
                if (std.fs.path.dirname(child_dst)) |parent| {
                    try std.fs.cwd().makePath(parent);
                }
                try std.fs.cwd().copyFile(child_src, std.fs.cwd(), child_dst, .{});
            },
            else => {},
        }
    }
}

fn replacePlaceholdersInFile(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    relative_path: []const u8,
    replacements: []const Replacement,
) !void {
    const full_path = try std.fs.path.join(allocator, &.{ root_path, relative_path });
    defer allocator.free(full_path);

    var file = std.fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var need_close = true;
    defer if (need_close) file.close();

    const content = file.readToEndAlloc(allocator, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileTooBig => return error.FileTooBig,
        else => return err,
    };
    file.close();
    need_close = false;

    var current = content;
    var changed = false;
    for (replacements) |rep| {
        if (std.mem.indexOf(u8, current, rep.needle) != null) {
            const next = try std.mem.replaceOwned(u8, allocator, current, rep.needle, rep.value);
            allocator.free(current);
            current = next;
            changed = true;
        }
    }

    if (!changed) {
        allocator.free(current);
        return;
    }

    try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = current });
    allocator.free(current);
}

fn packageToJniPrefix(allocator: std.mem.Allocator, app_id: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, app_id.len);
    for (app_id, 0..) |c, i| {
        buf[i] = if (c == '.') '_' else c;
    }
    return buf;
}

fn packageToPath(allocator: std.mem.Allocator, pkg: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, pkg.len);
    for (pkg, 0..) |c, i| {
        buf[i] = if (c == '.') '/' else c;
    }
    return buf;
}

fn relocateKotlinPackage(
    allocator: std.mem.Allocator,
    android_root: []const u8,
    old_pkg: []const u8,
    new_pkg: []const u8,
) !void {
    if (std.mem.eql(u8, old_pkg, new_pkg)) return;

    const kotlin_root = try std.fs.path.join(allocator, &.{ android_root, "app/src/main/kotlin" });
    defer allocator.free(kotlin_root);

    const old_rel = try packageToPath(allocator, old_pkg);
    defer allocator.free(old_rel);
    const new_rel = try packageToPath(allocator, new_pkg);
    defer allocator.free(new_rel);

    const old_full = try std.fs.path.join(allocator, &.{ kotlin_root, old_rel });
    defer allocator.free(old_full);
    const new_full = try std.fs.path.join(allocator, &.{ kotlin_root, new_rel });
    defer allocator.free(new_full);

    if (std.mem.eql(u8, old_full, new_full)) return;

    try std.fs.cwd().makePath(new_full);

    var src_dir = std.fs.cwd().openDir(old_full, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const from = try std.fs.path.join(allocator, &.{ old_full, entry.name });
        defer allocator.free(from);
        const to = try std.fs.path.join(allocator, &.{ new_full, entry.name });
        defer allocator.free(to);
        try std.fs.cwd().makePath(std.fs.path.dirname(to) orelse new_full);
        try std.fs.cwd().rename(from, to);
    }

    std.fs.cwd().deleteTree(old_full) catch {};
}

fn installNativeTemplate(
    allocator: std.mem.Allocator,
    templates_root: []const u8,
    project_root: []const u8,
    template: Template,
    replacements: []const Replacement,
) !void {
    const dest_native = try std.fs.path.join(allocator, &.{ project_root, "native" });
    defer allocator.free(dest_native);
    const src_native = try std.fs.path.join(allocator, &.{ templates_root, templateName(template), "native" });
    defer allocator.free(src_native);

    try copyTemplateTree(allocator, src_native, dest_native);
    try replacePlaceholdersInFile(allocator, dest_native, "ffi.zig", replacements);
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
            app_dir.access("build.gradle.kts", .{}) catch {
                has_build = false;
            };
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
