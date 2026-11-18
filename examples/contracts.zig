//! Looks up contracts in TWS.
//!
//! Usage:
//!   contracts search PATTERN
//!   contracts details SYMBOL [SECTYPE] [CURRENCY] [EXPIRY]
//!
//! SECTYPE is a TWS code (STK, OPT, FUT, IND, CASH, …; default STK),
//! CURRENCY defaults to USD. EXPIRY is YYYYMM or YYYYMMDD for derivatives.
//! Connection: Config.zon in the current directory (see common.zig).
//!
//! Examples:
//!   contracts search apple
//!   contracts details AAPL
//!   contracts details AAPL OPT USD 20261218
//!   contracts details ES FUT USD

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse return usage();

    const client = try common.connectFromConfig(init);
    defer client.close();

    var diag: ibapi.Client.Diagnostics = .{};
    if (std.mem.eql(u8, command, "search")) {
        const pattern = args.next() orelse return usage();
        var matches = try client.searchSymbols(gpa, pattern, .{ .diagnostics = &diag });
        defer matches.deinit();
        for (matches.items()) |d| {
            const c = d.contract orelse continue;
            try common.print(io, "{?d:>10}  {s:<8} {s:<5} {s:<4} {s:<10} derivatives: {s}\n", .{
                c.conId,
                c.symbol orelse "",
                c.secType orelse "",
                c.currency orelse "",
                c.primaryExch orelse "",
                try std.mem.join(init.arena.allocator(), ",", d.derivativeSecTypes.items),
            });
        }
    } else if (std.mem.eql(u8, command, "details")) {
        const symbol = args.next() orelse return usage();
        const sec_type_code = args.next() orelse "STK";
        const currency = args.next() orelse "USD";
        const expiry = args.next();

        const sec_type = ibapi.contract.SecType.fromCode(sec_type_code) orelse return usage();
        const query: ibapi.contract.Query = .{
            .symbol = symbol,
            .sec_type = sec_type,
            .currency = currency,
            .expiry = expiry,
            // Futures need their exchange; leaving it empty matches all of them.
            .exchange = if (sec_type == .future) null else "SMART",
        };
        // All options of a symbol can be thousands of contracts.
        var list = client.contractDetails(gpa, query, .{
            .timeout = .fromSeconds(60),
            .diagnostics = &diag,
        }) catch |err| switch (err) {
            error.RequestRejected => {
                try common.print(io, "TWS error {d}: {s}\n", .{ diag.code, diag.message() });
                return;
            },
            else => |e| return e,
        };
        defer list.deinit();
        for (list.items) |item| {
            const c = item.contract orelse continue;
            const d = item.contractDetails orelse ibapi.proto.ContractDetails{};
            try common.print(io, "{?d:>10}  {s:<22} {s:<4} {s:<8} {s:<10} {s:<4} {s}\n", .{
                c.conId,
                c.localSymbol orelse c.symbol orelse "",
                c.secType orelse "",
                c.exchange orelse "",
                c.primaryExch orelse "",
                c.currency orelse "",
                d.longName orelse "",
            });
        }
        try common.print(io, "{d} contracts\n", .{list.items.len});
    } else return usage();
}

fn usage() error{InvalidArguments} {
    std.log.err("usage: contracts search PATTERN | contracts details SYMBOL [SECTYPE] [CURRENCY] [EXPIRY]", .{});
    return error.InvalidArguments;
}
