//! Prints a market data snapshot of a stock or an option.
//!
//! Usage:
//!   quote SYMBOL                         stock (SMART, USD)
//!   quote SYMBOL EXPIRY STRIKE C|P       option, EXPIRY as YYYYMMDD
//!
//! Connection: Config.zon in the current directory (see common.zig).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");
const Query = ibapi.contract.Query;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const symbol = args.next() orelse return usage();
    const query: Query = if (args.next()) |expiry| blk: {
        const strike = try std.fmt.parseFloat(f64, args.next() orelse return usage());
        const right = ibapi.contract.Right.fromCode(args.next() orelse return usage()) orelse return usage();
        break :blk Query.option(symbol, "USD", expiry, strike, right);
    } else Query.stock(symbol, "USD");

    const client = try common.connectFromConfig(init);
    defer client.close();

    var diag: ibapi.Client.Diagnostics = .{};
    const q = client.snapshot(query, .{ .diagnostics = &diag }) catch |err| switch (err) {
        error.RequestRejected => return common.print(io, "TWS error {d}: {s}\n", .{ diag.code, diag.message() }),
        else => |e| return e,
    };

    try common.print(io, "data:   {s}\n", .{if (q.data_type) |t| t.name() else "?"});
    try common.print(io, "bid:    {?d} x {?d}\n", .{ q.bid, q.bid_size });
    try common.print(io, "ask:    {?d} x {?d}\n", .{ q.ask, q.ask_size });
    try common.print(io, "last:   {?d} x {?d} at {?d}\n", .{ q.last, q.last_size, q.last_timestamp });
    try common.print(io, "o/h/l:  {?d} / {?d} / {?d}, previous close {?d}\n", .{ q.open, q.high, q.low, q.close });
    try common.print(io, "volume: {?d}\n", .{q.volume});

    const sources = [_]struct { []const u8, ?ibapi.market_data.OptionComputation }{
        .{ "bid", q.bid_computation },
        .{ "ask", q.ask_computation },
        .{ "last", q.last_computation },
        .{ "model", q.model_computation },
    };
    for (sources) |s| {
        const m = s[1] orelse continue;
        try common.print(io, "{s:<6} iv {?d:.4}  delta {?d:.4}  gamma {?d:.4}  vega {?d:.4}  theta {?d:.4}  price {?d:.2}  und {?d:.2}\n", .{
            s[0], m.implied_vol, m.delta, m.gamma, m.vega, m.theta, m.option_price, m.underlying_price,
        });
    }
}

fn usage() error{InvalidArguments} {
    std.log.err("usage: quote SYMBOL | quote SYMBOL EXPIRY STRIKE C|P", .{});
    return error.InvalidArguments;
}
