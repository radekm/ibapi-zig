//! Connects to TWS / IB Gateway, prints connection details and the server
//! time, then prints notices until none arrives for 3 seconds.
//!
//! Usage: connect [host] [port] [client-id]
//!        (defaults: 127.0.0.1, 7497 = paper TWS, client id 1)

const std = @import("std");
const ibapi = @import("ibapi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const host = args.next() orelse "127.0.0.1";
    const port = if (args.next()) |a| try std.fmt.parseInt(u16, a, 10) else 7497;
    const client_id = if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else 1;

    const client = try ibapi.Client.connect(io, gpa, .{ .host = host, .port = port, .client_id = client_id });
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
