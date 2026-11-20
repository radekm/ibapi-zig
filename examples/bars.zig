//! Prints historical bars (OHLC) of a stock.
//!
//! Usage:
//!   bars SYMBOL minutes [HOURS]   1-minute bars of the last HOURS hours (default 1)
//!   bars SYMBOL days [DAYS]       1-day bars of the last DAYS days (default 30)
//!
//! Times of minute bars are printed in UTC. Connection: Config.zon in the
//! current directory (see common.zig).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");
const history = ibapi.history;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const symbol = args.next() orelse return usage();
    const kind = args.next() orelse return usage();
    const minutes = std.mem.eql(u8, kind, "minutes");
    if (!minutes and !std.mem.eql(u8, kind, "days")) return usage();
    const count = if (args.next()) |n| try std.fmt.parseInt(u32, n, 10) else @as(u32, if (minutes) 1 else 30);

    const client = try common.connectFromConfig(init);
    defer client.close();

    const query = ibapi.contract.Query.stock(symbol, "USD");
    var diag: ibapi.Client.Diagnostics = .{};
    const now = std.Io.Timestamp.now(io, .real);

    if (minutes) {
        const start = now.subDuration(.fromSeconds(@as(i64, count) * 3600));
        var bars = client.minuteBars(gpa, query, .{ .start = start }, .{ .diagnostics = &diag }) catch |err| switch (err) {
            error.RequestRejected => return common.print(io, "TWS error {d}: {s}\n", .{ diag.code, diag.message() }),
            else => |e| return e,
        };
        defer bars.deinit();
        for (bars.items) |b| {
            var buf: [17]u8 = undefined;
            const time = history.formatUtc(&buf, @intCast(history.floorSeconds(b.time)));
            try common.print(io, "{s}  o {?d:.2}  h {?d:.2}  l {?d:.2}  c {?d:.2}  v {?d}\n", .{ time, b.open, b.high, b.low, b.close, b.volume });
        }
        try common.print(io, "{d} bars\n", .{bars.items.len});
    } else {
        const today = @divFloor(history.floorSeconds(now), std.time.s_per_day);
        const first: history.Day = .{ .day = @intCast(@max(today - count, 0)) };
        var bars = client.dailyBars(gpa, query, .{ .first = first }, .{ .diagnostics = &diag }) catch |err| switch (err) {
            error.RequestRejected => return common.print(io, "TWS error {d}: {s}\n", .{ diag.code, diag.message() }),
            else => |e| return e,
        };
        defer bars.deinit();
        for (bars.items) |b| {
            const yd = b.day.calculateYearDay();
            const md = yd.calculateMonthDay();
            try common.print(io, "{d}-{d:0>2}-{d:0>2}  o {?d:.2}  h {?d:.2}  l {?d:.2}  c {?d:.2}  v {?d}\n", .{
                yd.year, md.month.numeric(), @as(u32, md.day_index) + 1, b.open, b.high, b.low, b.close, b.volume,
            });
        }
        try common.print(io, "{d} bars\n", .{bars.items.len});
    }
}

fn usage() error{InvalidArguments} {
    std.log.err("usage: bars SYMBOL minutes [HOURS] | bars SYMBOL days [DAYS]", .{});
    return error.InvalidArguments;
}
