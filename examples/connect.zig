//! Connects to TWS / IB Gateway, prints connection details and the server
//! time, then prints notices for a few seconds.
//!
//! Usage: connect [port] [client-id]   (defaults: 7497 = paper TWS, client id 1)

const std = @import("std");
const ibapi = @import("ibapi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const port = if (args.next()) |a| try std.fmt.parseInt(u16, a, 10) else 7497;
    const client_id = if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else 1;

    const client = try ibapi.Client.connect(io, gpa, .{ .port = port, .client_id = client_id });
    defer client.close();

    std.log.info("server version {d}, connected at {s}", .{ client.serverVersion(), client.connectionTime() });
    std.log.info("accounts: {s}", .{client.managedAccounts()});
    std.log.info("server time: {d}", .{try client.currentTime()});

    // Print notices (data farm status etc.) until a timeout cancels the reader.
    var notices = io.async(printNotices, .{ client, gpa });
    try io.sleep(.fromSeconds(3), .awake);
    notices.cancel(io) catch {};
}

fn printNotices(client: *ibapi.Client, gpa: std.mem.Allocator) !void {
    while (try client.nextNotice()) |notice| {
        var n = notice;
        defer n.deinit(gpa);
        switch (n) {
            .error_message => |m| std.log.info("notice {?d}: {s}", .{ m.errorCode, m.errorMsg orelse "" }),
            else => std.log.info("notice: message {d}", .{@backingInt(n.msgId())}),
        }
    }
}
