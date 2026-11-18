//! Lists orders (read-only).
//!
//! Usage:
//!   orders              open orders of all clients and of TWS
//!   orders completed    orders completed today
//!
//! Connection: IBAPI_HOST, IBAPI_PORT, IBAPI_CLIENT_ID (see common.zig).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common.zig");
const Order = ibapi.orders.Order;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse "all";

    const client = try common.connectFromEnv(init);
    defer client.close();

    var list = if (std.mem.eql(u8, mode, "all"))
        try client.openOrders(gpa, .{})
    else if (std.mem.eql(u8, mode, "completed"))
        try client.completedOrders(gpa, .{})
    else
        return usage();
    defer list.deinit();

    try common.print(io, "{d} orders\n", .{list.items.len});
    for (list.items) |*o| try printOrder(io, o);
}

fn printOrder(io: std.Io, o: *const Order) !void {
    const c = o.contract;
    try common.print(io, "#{d} perm {?d} client {?d} {s} {s} {?d} {s} {s} {s} {s}", .{
        o.order_id,
        o.permId(),
        o.clientId(),
        o.account() orelse "-",
        if (o.action()) |a| @tagName(a) else "?",
        o.totalQuantity(),
        c.symbol orelse "?",
        c.secType orelse "",
        c.lastTradeDateOrContractMonth orelse "",
        o.orderType() orelse "?",
    });
    if (o.limitPrice()) |p| try common.print(io, " lmt {d}", .{p});
    if (o.auxPrice()) |p| try common.print(io, " aux {d}", .{p});
    try common.print(io, " {s} | {t} filled {?d} remaining {?d} avg {?d}", .{
        o.timeInForce() orelse "",
        o.statusKind(),
        o.filledQuantity(),
        o.remainingQuantity(),
        o.avgFillPrice(),
    });
    if (o.state.completedTime) |t| try common.print(io, " | {s}: {s}", .{ t, o.state.completedStatus orelse "" });
    try common.print(io, "\n", .{});
}

fn usage() error{InvalidArguments} {
    std.log.err("usage: orders [all | completed]", .{});
    return error.InvalidArguments;
}
