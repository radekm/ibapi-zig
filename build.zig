const std = @import("std");
const builtin = @import("builtin");

/// Builds the `ibapi` module.
///
/// The `.proto` files of the TWS API are not part of this repository (they are
/// licensed by Interactive Brokers under GPL v3). Point the build at them with
/// `-Dproto-dir=<dir>`; Zig code for the messages is then generated into the
/// build cache by zig-protobuf.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const proto_dir = b.option(
        []const u8,
        "proto-dir",
        "Directory with the .proto files of the TWS API (e.g. <twsapi>/source/proto)",
    );
    const protoc_override = b.option(
        []const u8,
        "protoc",
        "Path to a protoc executable (default: protoc 36.2 downloaded by zig-protobuf)",
    );

    const protobuf_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
    const protobuf_mod = protobuf_dep.module("protobuf");

    const test_step = b.step("test", "Run unit tests");

    const dir = proto_dir orelse {
        const fail = b.addFail(
            \\The TWS API .proto files are required.
            \\Pass the directory that contains them: zig build -Dproto-dir=<twsapi>/source/proto
        );
        b.getInstallStep().dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    };

    const proto_mod = try generateProtoModule(b, .{
        .proto_dir = dir,
        .protoc = if (protoc_override) |p| .{ .cwd_relative = p } else null,
        .protobuf_dep = protobuf_dep,
        .protobuf_mod = protobuf_mod,
        .target = target,
        .optimize = optimize,
    }) orelse return; // A lazy dependency is being fetched; the build reruns.

    const ibapi_mod = b.addModule("ibapi", .{
        .root_source_file = b.path("src/ibapi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
            .{ .name = "ibapi_proto", .module = proto_mod },
        },
    });

    const unit_tests = b.addTest(.{ .root_module = ibapi_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Examples are built by `zig build examples` and also by `zig build test`,
    // so that they never go stale.
    const examples_step = b.step("examples", "Build the examples");
    for ([_][]const u8{"connect"}) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ibapi", .module = ibapi_mod }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
        test_step.dependOn(&exe.step);
    }
}

const ProtoOptions = struct {
    proto_dir: []const u8,
    protoc: ?std.Build.LazyPath,
    protobuf_dep: *std.Build.Dependency,
    protobuf_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// Runs protoc with the zig-protobuf generator over every `.proto` file in
/// `proto_dir` and returns a module rooted at the generated code. The output
/// lives in the build cache, so nothing generated ends up in the source tree.
/// Returns null while the lazily fetched protoc is not available yet.
fn generateProtoModule(b: *std.Build, opts: ProtoOptions) !?*std.Build.Module {
    const io = b.graph.io;

    // The generator always runs on the build host.
    const host_dep = b.dependency("protobuf", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const generator = host_dep.artifact("protoc-gen-zig");

    const protoc = opts.protoc orelse (protocFromRelease(host_dep) catch {
        @panic("zig-protobuf has no protoc release for this host; pass -Dprotoc=<path>");
    }) orelse return null;

    const run = b.addRunFile(protoc);
    run.setName("generate TWS API protobuf code");
    run.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", generator);
    const out_dir = run.addPrefixedOutputDirectoryArg("--zig_out=", "ibapi_proto");
    run.addArg("-I");
    run.addDirectoryArg(.{ .cwd_relative = opts.proto_dir });

    // Pass the files in a stable order so that the cache key is stable.
    var names: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, opts.proto_dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open -Dproto-dir={s}: {t}", .{ opts.proto_dir, err });
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".proto")) continue;
        try names.append(b.allocator, b.dupe(entry.name));
    }
    if (names.items.len == 0) {
        std.debug.panic("no .proto files found in -Dproto-dir={s}", .{opts.proto_dir});
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ opts.proto_dir, name }) });
    }

    return b.createModule(.{
        // All IB messages live in the protobuf package `protobuf`.
        .root_source_file = out_dir.path(b, "protobuf.pb.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{.{ .name = "protobuf", .module = opts.protobuf_mod }},
    });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Returns the protoc binary released by Google that zig-protobuf declares as
/// a lazy dependency, or null when the dependency has not been fetched yet.
fn protocFromRelease(dep: *std.Build.Dependency) error{UnsupportedHost}!?std.Build.LazyPath {
    const name: []const u8 = switch (builtin.os.tag) {
        .windows => "protoc-win64",
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "protoc-linux-x86_64",
            .x86 => "protoc-linux-x86_32",
            .aarch64 => "protoc-linux-aarch_64",
            else => return error.UnsupportedHost,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "protoc-osx-x86_64",
            .aarch64 => "protoc-osx-aarch_64",
            else => return error.UnsupportedHost,
        },
        else => return error.UnsupportedHost,
    };
    const protoc_dep = dep.builder.lazyDependency(name, .{}) orelse return null;
    const exe = if (builtin.os.tag == .windows) "bin/protoc.exe" else "bin/protoc";
    return protoc_dep.path(exe);
}
