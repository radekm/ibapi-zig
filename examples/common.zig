//! Helpers shared by the example programs and the integration test.

const std = @import("std");
const ibapi = @import("ibapi");

/// Name of the configuration file, looked up in the current working directory.
pub const config_path = "Config.zon";

/// Connection settings read from `Config.zon`. See `examples/Config.example.zon`.
/// All fields are required, so that the programs never connect to an
/// unintended TWS (e.g. a live instead of a paper account).
pub const Config = struct {
    /// Host name or IP address of TWS / IB Gateway.
    host: []const u8,
    /// API port: 7497 paper TWS, 7496 live TWS, 4002 paper Gateway, 4001 live Gateway.
    port: u16,
    /// Client id; must be unique among clients connected at the same time.
    client_id: i32,
};

/// Reads `Config.zon` from the current working directory. Strings in the
/// result are allocated with `arena`.
pub fn readConfig(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !Config {
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, config_path, arena, .limited(64 * 1024), .of(u8), 0) catch |err| {
        switch (err) {
            error.FileNotFound => std.log.err("{s} not found in the current directory; copy examples/Config.example.zon to {s} and edit it", .{ config_path, config_path }),
            else => std.log.err("cannot read {s}: {t}", .{ config_path, err }),
        }
        return error.InvalidConfig;
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diagnostics.log(config_path);
            return error.InvalidConfig;
        },
    };
}

/// Connects to TWS / IB Gateway using `Config.zon` from the current
/// working directory.
pub fn connectFromConfig(init: std.process.Init) !*ibapi.Client {
    const config = try readConfig(init.io, init.gpa, init.arena.allocator());
    return ibapi.Client.connect(init.io, init.gpa, .{
        .host = config.host,
        .port = config.port,
        .client_id = config.client_id,
    });
}

/// Prints to stdout.
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

test "the example configuration parses" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const config = try std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .source = @embedFile("Config.example.zon"),
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(@as(u16, 7497), config.port);
}
