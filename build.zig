const std = @import("std");
const builtin = @import("builtin");

/// Path of the Zig code generated from the TWS API `.proto` files. It is
/// committed, so building the library needs neither the `.proto` files nor protoc.
const generated_proto = "src/proto/protobuf.pb.zig";

/// Builds the `ibapi` module.
///
/// `zig build gen-proto -Dproto-dir=<dir>` regenerates `src/proto` from the
/// `.proto` files of a TWS API release with zig-protobuf.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protobuf_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
    const protobuf_mod = protobuf_dep.module("protobuf");

    const proto_mod = b.createModule(.{
        // All IB messages live in the protobuf package `protobuf`.
        .root_source_file = b.path(generated_proto),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf_mod }},
    });

    const ibapi_mod = b.addModule("ibapi", .{
        .root_source_file = b.path("src/ibapi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
            .{ .name = "ibapi_proto", .module = proto_mod },
        },
    });

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .root_module = ibapi_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Examples are built by `zig build examples` and also by `zig build test`,
    // so that they never go stale.
    const examples_step = b.step("examples", "Build the examples");
    for ([_][]const u8{ "connect", "contracts", "option_chain", "quote", "orders" }) |name| {
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
    // Tests of the shared example code (e.g. that Config.example.zon parses).
    const example_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ibapi", .module = ibapi_mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    // Opt-in test against a paper TWS / IB Gateway. `zig build test` only
    // compiles it.
    const integration = b.addExecutable(.{
        .name = "integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ibapi", .module = ibapi_mod }},
        }),
    });
    test_step.dependOn(&integration.step);
    const integration_step = b.step("test-integration", "Run the integration test against a paper TWS (IBAPI_HOST, IBAPI_PORT, IBAPI_CLIENT_ID)");
    const run_integration = b.addRunArtifact(integration);
    run_integration.has_side_effects = true;
    integration_step.dependOn(&run_integration.step);

    // API reference generated from the doc comments: zig-out/docs.
    const docs_obj = b.addObject(.{ .name = "ibapi", .root_module = ibapi_mod });
    const docs_step = b.step("docs", "Generate the API reference into zig-out/docs");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    try addGenProtoStep(b);
}

/// `zig build gen-proto -Dproto-dir=<dir> [-Dprotoc=<path>]`
fn addGenProtoStep(b: *std.Build) !void {
    const gen_step = b.step("gen-proto", "Regenerate " ++ generated_proto ++ " from -Dproto-dir");

    const proto_dir = b.option(
        []const u8,
        "proto-dir",
        "gen-proto: directory with the .proto files of the TWS API (e.g. <twsapi>/source/proto)",
    );
    const protoc_override = b.option(
        []const u8,
        "protoc",
        "gen-proto: path to a protoc executable (default: protoc 36.2 downloaded by zig-protobuf)",
    );

    const dir = proto_dir orelse {
        const fail = b.addFail("gen-proto needs the TWS API .proto files: zig build gen-proto -Dproto-dir=<twsapi>/source/proto");
        gen_step.dependOn(&fail.step);
        return;
    };

    // The generator always runs on the build host.
    const host_dep = b.dependency("protobuf", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const generator = host_dep.artifact("protoc-gen-zig");
    const protoc: std.Build.LazyPath = if (protoc_override) |p| .{ .cwd_relative = p } else (protocFromRelease(host_dep) catch {
        @panic("zig-protobuf has no protoc release for this host; pass -Dprotoc=<path>");
    }) orelse return; // protoc is being fetched lazily; the build reruns.

    const run = b.addRunFile(protoc);
    run.setName("generate TWS API protobuf code");
    run.addPrefixedArtifactArg("--plugin=protoc-gen-zig=", generator);
    const out_dir = run.addPrefixedOutputDirectoryArg("--zig_out=", "ibapi_proto");
    run.addArg("-I");
    run.addDirectoryArg(.{ .cwd_relative = dir });
    for (try listProtoFiles(b, dir)) |name| {
        run.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ dir, name }) });
    }

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(out_dir.path(b, "protobuf.pb.zig"), generated_proto);
    gen_step.dependOn(&update.step);
}

/// Names of the `.proto` files in `dir`, sorted so that the cache key is stable.
fn listProtoFiles(b: *std.Build, dir_path: []const u8) ![]const []const u8 {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open -Dproto-dir={s}: {t}", .{ dir_path, err });
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".proto")) continue;
        try names.append(b.allocator, b.dupe(entry.name));
    }
    if (names.items.len == 0) {
        std.debug.panic("no .proto files found in -Dproto-dir={s}", .{dir_path});
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
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
