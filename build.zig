const std = @import("std");

/// Mirrors `src/dev.zig` in the Zig source tree. Keep in sync when bumping Zig.
const DevEnv = enum {
    bootstrap,
    core,
    full,
    c_source,
    ast_gen,
    sema,
    @"aarch64-linux",
    cbe,
    @"powerpc-linux",
    @"riscv64-linux",
    spirv,
    wasm,
    @"x86_64-linux",
    @"x86_64-windows",
    @"loongarch-linux",
    spork8,
};

const IoMode = enum { threaded, evented };
const ValueInterpretMode = enum { direct, by_name };

const zig_git_url = "https://codeberg.org/ziglang/zig";
const default_zig_ref = "0.17.0";

const Replacement = struct {
    from: []const u8,
    to: []const u8,
};

const WasmOptFeature = struct {
    feature: std.Target.wasm.Feature,
    flag: []const u8,
};

/// Feature gates passed to wasm-opt when the corresponding wasm feature is
/// enabled by the requested target/CPU.
const wasm_opt_features = [_]WasmOptFeature{
    .{ .feature = .atomics, .flag = "--enable-threads" },
    .{ .feature = .bulk_memory, .flag = "--enable-bulk-memory" },
    .{ .feature = .bulk_memory_opt, .flag = "--enable-bulk-memory-opt" },
    .{ .feature = .call_indirect_overlong, .flag = "--enable-call-indirect-overlong" },
    .{ .feature = .exception_handling, .flag = "--enable-exception-handling" },
    .{ .feature = .extended_const, .flag = "--enable-extended-const" },
    .{ .feature = .fp16, .flag = "--enable-fp16" },
    .{ .feature = .gc, .flag = "--enable-gc" },
    .{ .feature = .multimemory, .flag = "--enable-multimemory" },
    .{ .feature = .multivalue, .flag = "--enable-multivalue" },
    .{ .feature = .mutable_globals, .flag = "--enable-mutable-globals" },
    .{ .feature = .nontrapping_fptoint, .flag = "--enable-nontrapping-float-to-int" },
    .{ .feature = .reference_types, .flag = "--enable-reference-types" },
    .{ .feature = .relaxed_simd, .flag = "--enable-relaxed-simd" },
    .{ .feature = .sign_ext, .flag = "--enable-sign-ext" },
    .{ .feature = .simd128, .flag = "--enable-simd" },
    .{ .feature = .tail_call, .flag = "--enable-tail-call" },
    .{ .feature = .wide_arithmetic, .flag = "--enable-wide-arithmetic" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The self-hosted Zig backends crash for every architecture except wasm
    // (and x86). This project only ever builds the wasm32 compiler, so refuse
    // any other target loudly instead of taking down the machine.
    if (target.result.cpu.arch != .wasm32) {
        std.debug.panic(
            "zig-bootstrap-wasm only supports wasm32 targets, got '{s}'.\n" ++
                "Use e.g. -Dtarget=wasm32-wasi. The self-hosted Zig backends are unstable for other targets.",
            .{@tagName(target.result.cpu.arch)},
        );
    }

    const dev = b.option(DevEnv, "dev", "Compiler feature set to build: " ++
        "bootstrap, core, full, ..., wasm (default: full)") orelse .full;
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const version_string = b.option([]const u8, "version-string", "Override the Zig version string") orelse "0.17.0";
    const zig_dir = b.option([]const u8, "zig-dir", "Path to the Zig source checkout") orelse "zig";
    const zig_ref = b.option([]const u8, "zig-ref", "Git ref to fetch when the Zig checkout is missing") orelse default_zig_ref;
    const install_lib = b.option(bool, "install-lib", "Install the compiler's lib/ directory") orelse true;
    const flat = b.option(bool, "flat", "Install the compiler directly into the prefix instead of prefix/bin") orelse false;
    const use_wasm_opt = b.option(bool, "wasm-opt", "Run wasm-opt on the compiler for non-Debug builds") orelse true;

    // Make sure the Zig source tree exists and carries the required fixes.
    ensureZigSource(b, zig_dir, zig_ref);
    applyZigPatches(b, zig_dir);

    const semver: std.SemanticVersion = std.SemanticVersion.parse(version_string) catch std.SemanticVersion{
        .major = 0,
        .minor = 17,
        .patch = 0,
    };
    const version_z = b.allocator.dupeSentinel(u8, version_string, 0) catch @panic("OOM");

    // `addExecutable` is the build-system spelling of a manual
    // `zig build-exe` invocation, which is what we want: the wasm32-wasi
    // compiler cannot spawn child processes, so `zig build` would not work
    // when this artifact runs itself.
    const exe = b.addExecutable(.{
        .name = "zig",
        .max_rss = 8_000_000_000,
        .root_module = b.createModule(.{
            .root_source_file = zigLazyPath(b, zig_dir, "src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
        // Enforce the fast, LLVM-free path no matter what the user passes.
        .use_llvm = false,
        .use_lld = false,
        .zig_lib_dir = zigLazyPath(b, zig_dir, "lib"),
    });
    exe.stack_size = 46 * 1024 * 1024;

    const options = b.addOptions();
    exe.root_module.addOptions("build_options", options);
    options.addOption(u32, "mem_leak_frames", if (strip) 0 else 4);
    options.addOption(bool, "have_llvm", false);
    options.addOption(bool, "llvm_has_m68k", false);
    options.addOption(bool, "llvm_has_csky", false);
    options.addOption(bool, "llvm_has_arc", false);
    options.addOption(bool, "llvm_has_xtensa", false);
    options.addOption(bool, "debug_gpa", false);
    options.addOption(DevEnv, "dev", dev);
    options.addOption(IoMode, "io_mode", .threaded);
    options.addOption(ValueInterpretMode, "value_interpret_mode", .direct);
    options.addOption([:0]const u8, "version", version_z);
    options.addOption(std.SemanticVersion, "semver", semver);
    options.addOption(bool, "enable_debug_extensions", false);
    options.addOption(bool, "enable_logging", false);
    options.addOption(bool, "enable_tracy", false);
    options.addOption(bool, "enable_tracy_callstack", false);
    options.addOption(bool, "enable_tracy_allocation", false);
    options.addOption(u32, "tracy_callstack_depth", 0);
    options.addOption(bool, "value_tracing", false);

    // Registers the artifact as "zig" so dependents can use
    // `dep.artifact("zig")` exactly like example/build.zig does.
    //
    // Release builds get post-processed by wasm-opt with every feature enabled
    // by the requested CPU. The optimized file becomes the installed artifact
    // (and `dep.namedLazyPath("zig")`); the raw `Step.Compile` stays available
    // through `dep.artifact("zig")` because `dep.artifact` can only return
    // compile steps.
    const run_wasm_opt = use_wasm_opt and optimize != .debug;

    const install_raw = b.addInstallArtifact(exe, .{
        .dest_dir = if (run_wasm_opt)
            .disabled
        else if (flat)
            .{ .override = .prefix }
        else
            .default,
    });
    b.getInstallStep().dependOn(&install_raw.step);

    if (run_wasm_opt) {
        const wasm_opt = b.addSystemCommand(&.{"wasm-opt"});
        wasm_opt.addArg(switch (optimize) {
            .debug => unreachable,
            .small => "-Oz",
            .fast, .safe => "-O3",
        });
        inline for (wasm_opt_features) |feature_flag| {
            if (target.result.cpu.features.isEnabled(@intFromEnum(feature_flag.feature))) {
                wasm_opt.addArg(feature_flag.flag);
            }
        }
        wasm_opt.addArtifactArg(exe);
        wasm_opt.addArg("-o");
        const optimized = wasm_opt.addOutputFileArg("zig.wasm");

        const install_dir: std.Build.InstallDir = if (flat) .prefix else .bin;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(optimized, install_dir, "zig.wasm").step);
        b.addNamedLazyPath("zig", optimized);
    } else {
        b.addNamedLazyPath("zig", exe.getEmittedBin());
    }

    if (install_lib) {
        b.installDirectory(.{
            .source_dir = zigLazyPath(b, zig_dir, "lib"),
            .install_dir = .prefix,
            .install_subdir = "lib",
            .exclude_extensions = &.{
                ".expect", ".input", ".lzma", ".xz", ".tzif", ".tar", ".zip",
                ".idx",  ".pack",  "README.md",
            },
            .blank_extensions = &.{"test.zig"},
        });
    }
}

/// The Zig compiler needs a lib/ directory at runtime. We keep using the
/// checkout in the repository (or fetch one on demand) and patch it in place.
fn ensureZigSource(b: *std.Build, zig_dir: []const u8, zig_ref: []const u8) void {
    if (zigSourceExists(b, zig_dir)) return;

    const io = b.graph.io;
    const dest = pathFromBuildRoot(b, zig_dir);
    const cwd: std.process.Child.Cwd = if (std.fs.path.isAbsolute(dest))
        .inherit
    else
        .{ .dir = b.root.root_dir.handle };

    const result = std.process.run(b.allocator, io, .{
        .argv = &.{
            "git",   "clone", "--depth", "1",
            "--branch", zig_ref, zig_git_url, dest,
        },
        .cwd = cwd,
    }) catch |err| std.debug.panic("failed to run git clone for Zig: {s}", .{@errorName(err)});

    if (!result.term.success()) {
        std.debug.panic("failed to fetch Zig '{s}' from {s}:\n{s}", .{
            zig_ref, zig_git_url, result.stderr,
        });
    }
}

fn zigSourceExists(b: *std.Build, zig_dir: []const u8) bool {
    const io = b.graph.io;
    const rel = b.pathJoin(&.{ zig_dir, "src", "main.zig" });
    if (std.fs.path.isAbsolute(rel)) {
        const file = std.Io.Dir.cwd().openFile(io, rel, .{}) catch return false;
        file.close(io);
    } else {
        const file = b.root.openFile(io, rel, .{}) catch return false;
        file.close(io);
    }
    return true;
}

/// Applies this project's fixes to the Zig standard library:
///
/// 1. `std.wasm.AtomicsOpcode`: three `sub` opcodes were encoded with a stray
///    `A` (`0x27A`, `0x28A`, `0x29A`), producing invalid wasm modules
///    ("unknown 0xfe subopcode: 0x27a") as soon as `+atomics` is enabled.
/// 2. `std.debug.panicking`: the compiler used to emit the wasm module is the
///    host Zig, which still contains the buggy enum above, so its backend
///    would emit the invalid opcode whenever the compiled program performs a
///    u8 atomic `Sub` (which `std.debug.panicking` does). Widening the counter
///    to u32 sidesteps the host bug while keeping semantics identical. The
///    produced compiler still gets the fixed enum from (1).
fn applyZigPatches(b: *std.Build, zig_dir: []const u8) void {
    patchFile(b, zig_dir, "lib/std/wasm.zig", &.{
        .{ .from = "i32_atomic_rmw8_sub_u = 0x27A,", .to = "i32_atomic_rmw8_sub_u = 0x27," },
        .{ .from = "i32_atomic_rmw16_sub_u = 0x28A,", .to = "i32_atomic_rmw16_sub_u = 0x28," },
        .{ .from = "i64_atomic_rmw8_sub_u = 0x29A,", .to = "i64_atomic_rmw8_sub_u = 0x29," },
    });
    patchFile(b, zig_dir, "lib/std/debug.zig", &.{
        .{
            .from = "var panicking = std.atomic.Value(u8).init(0);",
            .to = "var panicking = std.atomic.Value(u32).init(0);",
        },
    });
}

fn patchFile(
    b: *std.Build,
    zig_dir: []const u8,
    sub_path: []const u8,
    replacements: []const Replacement,
) void {
    const rel = b.pathJoin(&.{ zig_dir, sub_path });

    const original = readSourceFile(b, rel) catch |err| std.debug.panic(
        "unable to read '{s}': {s}",
        .{ rel, @errorName(err) },
    );
    defer b.allocator.free(original);

    var owned: ?[]u8 = null;
    defer if (owned) |p| b.allocator.free(p);

    var current: []const u8 = original;
    for (replacements) |replacement| {
        if (std.mem.find(u8, current, replacement.from) == null) continue;
        const next = replaceAll(b.allocator, current, replacement.from, replacement.to);
        if (owned) |p| b.allocator.free(p);
        owned = next;
        current = next;
    }

    const final = owned orelse return;
    writeSourceFile(b, rel, final) catch |err| std.debug.panic(
        "unable to write '{s}': {s}",
        .{ rel, @errorName(err) },
    );
}

fn replaceAll(gpa: std.mem.Allocator, haystack: []const u8, from: []const u8, to: []const u8) []u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.find(u8, haystack[i..], from)) |found| {
        count += 1;
        i += found + from.len;
    }
    if (count == 0) return gpa.dupe(u8, haystack) catch @panic("OOM");

    const out = gpa.alloc(u8, haystack.len - count * from.len + count * to.len) catch @panic("OOM");

    var src: usize = 0;
    var dst: usize = 0;
    while (std.mem.find(u8, haystack[src..], from)) |found| {
        const at = src + found;
        @memcpy(out[dst..][0 .. at - src], haystack[src..at]);
        dst += at - src;
        @memcpy(out[dst..][0..to.len], to);
        dst += to.len;
        src = at + from.len;
    }
    @memcpy(out[dst..], haystack[src..]);
    return out;
}

fn readSourceFile(b: *std.Build, rel: []const u8) ![]u8 {
    const io = b.graph.io;
    const file = if (std.fs.path.isAbsolute(rel))
        try std.Io.Dir.cwd().openFile(io, rel, .{})
    else
        try b.root.openFile(io, rel, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(b.allocator, .limited(1 << 22));
}

fn writeSourceFile(b: *std.Build, rel: []const u8, data: []const u8) !void {
    const io = b.graph.io;
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var atomic = if (std.fs.path.isAbsolute(rel))
        try std.Io.Dir.cwd().createFileAtomic(io, rel, .{ .replace = true })
    else
        try b.root.atomicFile(io, rel, .{ .replace = true }, &path_buf);
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

/// Joins `zig_dir`/`sub_path` with the package root, returning either a
/// build-root relative `LazyPath` or a cwd-relative one for absolute paths.
fn zigLazyPath(b: *std.Build, zig_dir: []const u8, sub_path: []const u8) std.Build.LazyPath {
    const joined = b.pathJoin(&.{ zig_dir, sub_path });
    if (std.fs.path.isAbsolute(joined)) return b.graph.cwdRelativePath(joined);
    return b.path(joined);
}

fn pathFromBuildRoot(b: *std.Build, sub_path: []const u8) []const u8 {
    if (b.root.sub_path.len == 0) return sub_path;
    return b.pathJoin(&.{ b.root.sub_path, sub_path });
}
