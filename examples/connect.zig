//! Connects to TWS / IB Gateway, prints connection details and the server
//! time, then prints notices until none arrives for 3 seconds.
//!
//! Connection: IBAPI_HOST, IBAPI_PORT, IBAPI_CLIENT_ID (see common.zig).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const client = try common.connectFromEnv(init);
    defer client.close();

    std.log.info("server version {d}, connected at {s}", .{ client.serverVersion(), client.connectionTime() });
    std.log.info("accounts: {s}", .{client.managedAccounts()});
    std.log.info("server time: {d}", .{try client.currentTime()});

    // Print notices (data farm status etc.) until none arrives for 3 seconds.
    const quiet: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };
    while (client.nextNotice(quiet) catch |err| switch (err) {
        error.Timeout => null,
        else => |e| return e,
    }) |notice| {
        var n = notice;
        defer n.deinit(gpa);
        switch (n) {
            .error_message => |m| std.log.info("notice {?d}: {s}", .{ m.errorCode, m.errorMsg orelse "" }),
            else => std.log.info("notice: message {d}", .{@backingInt(n.msgId())}),
        }
    }
}
