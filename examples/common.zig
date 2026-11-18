//! Shared helpers of the examples.

const std = @import("std");
const ibapi = @import("ibapi");

/// Connects using the environment variables IBAPI_HOST (default 127.0.0.1),
/// IBAPI_PORT (default 7497, paper TWS) and IBAPI_CLIENT_ID (default 1).
pub fn connectFromEnv(init: std.process.Init) !*ibapi.Client {
    const env = init.environ_map;
    const host = env.get("IBAPI_HOST") orelse "127.0.0.1";
    const port = if (env.get("IBAPI_PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 7497;
    const client_id = if (env.get("IBAPI_CLIENT_ID")) |id| try std.fmt.parseInt(i32, id, 10) else 1;
    return ibapi.Client.connect(init.io, init.gpa, .{ .host = host, .port = port, .client_id = client_id });
}

/// Prints to stdout.
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
