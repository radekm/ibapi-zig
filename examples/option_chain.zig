//! Shows the option chain of a stock: expirations within MAX_DAYS days
//! (from SecDefOptParams) and the actual strikes of the nearest of them
//! (from contract details of its call options).
//!
//! Usage: option_chain SYMBOL [MAX_DAYS] [CURRENCY]   (defaults: 45, USD)
//! Connection: IBAPI_HOST, IBAPI_PORT, IBAPI_CLIENT_ID (see common.zig).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");
const Query = ibapi.contract.Query;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const symbol = args.next() orelse {
        std.log.err("usage: option_chain SYMBOL [MAX_DAYS] [CURRENCY]", .{});
        return error.InvalidArguments;
    };
    const max_days = if (args.next()) |a| try std.fmt.parseInt(i64, a, 10) else 45;
    const currency = args.next() orelse "USD";

    const client = try common.connectFromEnv(init);
    defer client.close();

    // 1. The underlying's contract id.
    var stocks = try client.contractDetails(gpa, Query.stock(symbol, currency), .{});
    defer stocks.deinit();
    if (stocks.items.len == 0) return error.UnderlyingNotFound;
    const con_id = stocks.items[0].contract.?.conId.?;

    // 2. Expirations of all trading classes (SMART only, other exchanges list the same).
    var chain = try client.optionChainParams(gpa, .{ .symbol = symbol, .con_id = con_id }, .{});
    defer chain.deinit();

    const today = epochDay(io);
    var nearest: ?[]const u8 = null;
    for (chain.items) |p| {
        if (!std.mem.eql(u8, p.exchange orelse "", "SMART")) continue;
        try common.print(io, "trading class {s}, multiplier {s}, expirations within {d} days:\n", .{
            p.tradingClass orelse "", p.multiplier orelse "", max_days,
        });
        for (p.expirations.items) |expiry| {
            const days = (parseDay(expiry) orelse continue) - today;
            if (days < 0 or days > max_days) continue;
            try common.print(io, "  {s}  ({d} days)\n", .{ expiry, days });
            if (nearest == null or std.mem.lessThan(u8, expiry, nearest.?)) nearest = expiry;
        }
    }

    // 3. Actual strikes of the nearest expiration.
    const expiry = nearest orelse return common.print(io, "no expiration within {d} days\n", .{max_days});
    var calls = try client.contractDetails(gpa, Query.option(symbol, currency, expiry, null, .call), .{
        .timeout = .fromSeconds(30),
    });
    defer calls.deinit();

    var strikes: std.ArrayList(f64) = .empty;
    for (calls.items) |item| try strikes.append(arena, item.contract.?.strike orelse continue);
    std.mem.sort(f64, strikes.items, {}, std.sort.asc(f64));
    try common.print(io, "strikes of {s} ({d} call contracts):\n", .{ expiry, calls.items.len });
    for (strikes.items) |s| try common.print(io, "  {d}\n", .{s});
}

/// Days since 1970-01-01 today (UTC).
fn epochDay(io: std.Io) i64 {
    const ms = std.Io.Clock.real.now(io).toMilliseconds();
    return @divFloor(ms, std.time.ms_per_day);
}

/// Days since 1970-01-01 of a YYYYMMDD date.
fn parseDay(s: []const u8) ?i64 {
    if (s.len != 8) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[4..6], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[6..8], 10) catch return null;
    // Days-from-civil algorithm (proleptic Gregorian calendar).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test parseDay {
    try std.testing.expectEqual(@as(?i64, 0), parseDay("19700101"));
    try std.testing.expectEqual(@as(?i64, 20775), parseDay("20261118"));
    try std.testing.expectEqual(@as(?i64, null), parseDay("202612"));
}
