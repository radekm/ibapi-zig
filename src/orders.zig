//! Orders as reported by TWS (`Client.openOrders`, `Client.completedOrders`).
//!
//! This module only describes orders; the library cannot place, modify or
//! cancel them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("ibapi_proto");

const log = std.log.scoped(.ibapi);

/// Status of an order as reported by TWS.
pub const Status = enum {
    /// Not yet sent to TWS by the API client.
    api_pending,
    /// Transmitted, but not yet confirmed by the order destination.
    pending_submit,
    /// A cancellation was requested but not yet confirmed.
    pending_cancel,
    /// Accepted but not yet working at the exchange (e.g. a simulated order
    /// waiting for its trigger).
    pre_submitted,
    /// Working at the exchange.
    submitted,
    /// Cancelled by the API client before it was submitted.
    api_cancelled,
    /// Cancelled.
    cancelled,
    /// Completely filled.
    filled,
    /// Neither working nor cancelled, e.g. rejected or waiting outside
    /// trading hours; see `Order.status.whyHeld` / `Order.state.rejectReason`.
    inactive,
    /// A status this version of the library does not know.
    unknown,

    const names = [_]struct { []const u8, Status }{
        .{ "ApiPending", .api_pending },
        .{ "PendingSubmit", .pending_submit },
        .{ "PendingCancel", .pending_cancel },
        .{ "PreSubmitted", .pre_submitted },
        .{ "Submitted", .submitted },
        .{ "ApiCancelled", .api_cancelled },
        .{ "Cancelled", .cancelled },
        .{ "Filled", .filled },
        .{ "Inactive", .inactive },
    };

    /// Parses the status text used by TWS, e.g. "PreSubmitted".
    pub fn parse(text: []const u8) Status {
        for (names) |n| {
            if (std.mem.eql(u8, n[0], text)) return n[1];
        }
        return .unknown;
    }

    /// Whether the order can still be filled.
    pub fn isActive(s: Status) bool {
        return switch (s) {
            .api_pending, .pending_submit, .pending_cancel, .pre_submitted, .submitted => true,
            .api_cancelled, .cancelled, .filled, .inactive, .unknown => false,
        };
    }
};

/// Side of an order.
pub const Action = enum {
    buy,
    sell,
    /// Short sale of a stock (`SSHORT`), used by institutional accounts.
    sell_short,

    /// Parses the TWS code (`BUY`, `SELL`, `SSHORT`).
    pub fn fromCode(code: []const u8) ?Action {
        if (std.mem.eql(u8, code, "BUY")) return .buy;
        if (std.mem.eql(u8, code, "SELL")) return .sell;
        if (std.mem.eql(u8, code, "SSHORT")) return .sell_short;
        return null;
    }
};

/// One order: its contract, parameters and state, plus the latest status
/// update. All memory is owned by the order and freed with `deinit`.
///
/// The protobuf fields hold everything TWS sent; the methods give typed
/// access to the most common values.
pub const Order = struct {
    /// Order id given by the API client that placed the order. 0 for orders
    /// entered in TWS (unless bound to API client 0) and for completed orders.
    order_id: i32 = 0,
    /// The instrument.
    contract: proto.Contract = .{},
    /// Order parameters: action, quantity, type, prices, time in force, account, …
    order: proto.Order = .{},
    /// State from the open order message: status text, commission and margin
    /// estimates; for completed orders also `completedTime` and `completedStatus`.
    state: proto.OrderState = .{},
    /// The latest `OrderStatus` received for the order (filled and remaining
    /// quantity, average fill price, why held). Null for completed orders
    /// and when TWS sent none.
    status: ?proto.OrderStatus = null,

    /// Copies an `OpenOrder` message.
    pub fn fromOpenOrder(gpa: Allocator, m: proto.OpenOrder) Allocator.Error!Order {
        var o: Order = .{ .order_id = m.orderId orelse (if (m.order) |ord| ord.orderId orelse 0 else 0) };
        errdefer o.deinit(gpa);
        if (m.contract) |c| o.contract = try c.dupe(gpa);
        if (m.order) |ord| o.order = try ord.dupe(gpa);
        if (m.orderState) |s| o.state = try s.dupe(gpa);
        return o;
    }

    /// Copies a `CompletedOrder` message.
    pub fn fromCompletedOrder(gpa: Allocator, m: proto.CompletedOrder) Allocator.Error!Order {
        var o: Order = .{ .order_id = if (m.order) |ord| ord.orderId orelse 0 else 0 };
        errdefer o.deinit(gpa);
        if (m.contract) |c| o.contract = try c.dupe(gpa);
        if (m.order) |ord| o.order = try ord.dupe(gpa);
        if (m.orderState) |s| o.state = try s.dupe(gpa);
        return o;
    }

    /// Frees the order.
    pub fn deinit(o: *Order, gpa: Allocator) void {
        o.contract.deinit(gpa);
        o.order.deinit(gpa);
        o.state.deinit(gpa);
        if (o.status) |*s| s.deinit(gpa);
        o.* = undefined;
    }

    /// Permanent id assigned by TWS; unique across clients and sessions.
    /// Returned as TWS sent it (from the order, else from the status update).
    pub fn permId(o: *const Order) ?i64 {
        if (o.order.permId) |id| return id;
        if (o.status) |s| return s.permId;
        return null;
    }

    /// Id of the API client that placed the order (0 also for TWS orders).
    pub fn clientId(o: *const Order) ?i32 {
        if (o.status) |s| if (s.clientId) |id| return id;
        return o.order.clientId;
    }

    /// Order id of the parent order (bracket orders), as TWS sent it (from
    /// the order, else from the status update).
    pub fn parentId(o: *const Order) ?i32 {
        if (o.order.parentId) |id| return id;
        if (o.status) |s| return s.parentId;
        return null;
    }

    /// Account the order belongs to.
    pub fn account(o: *const Order) ?[]const u8 {
        return o.order.account;
    }

    /// Buy or sell; null for codes the library does not know.
    pub fn action(o: *const Order) ?Action {
        return Action.fromCode(o.order.action orelse return null);
    }

    /// Order type code, e.g. `LMT`, `MKT`, `STP`, `STP LMT`, `TRAIL`.
    pub fn orderType(o: *const Order) ?[]const u8 {
        return o.order.orderType;
    }

    /// Time in force, e.g. `DAY`, `GTC`, `IOC`.
    pub fn timeInForce(o: *const Order) ?[]const u8 {
        return o.order.tif;
    }

    /// Status from the latest status update, or from the order state.
    pub fn statusKind(o: *const Order) Status {
        if (o.status) |s| if (s.status) |text| if (text.len > 0) return Status.parse(text);
        if (o.state.status) |text| return Status.parse(text);
        return .unknown;
    }

    /// Ordered quantity.
    pub fn totalQuantity(o: *const Order) ?f64 {
        return parseDecimal(o.order.totalQuantity);
    }

    /// Quantity filled so far.
    pub fn filledQuantity(o: *const Order) ?f64 {
        if (o.status) |s| if (parseDecimal(s.filled)) |v| return v;
        return parseDecimal(o.order.filledQuantity);
    }

    /// Quantity still to be filled (from the latest status update).
    pub fn remainingQuantity(o: *const Order) ?f64 {
        const s = o.status orelse return null;
        return parseDecimal(s.remaining);
    }

    /// Average price of the fills so far (from the latest status update).
    pub fn avgFillPrice(o: *const Order) ?f64 {
        const s = o.status orelse return null;
        return s.avgFillPrice;
    }

    /// Limit price (limit orders).
    pub fn limitPrice(o: *const Order) ?f64 {
        return o.order.lmtPrice;
    }

    /// Auxiliary price: the stop price of stop orders, the trailing amount of
    /// trailing orders.
    pub fn auxPrice(o: *const Order) ?f64 {
        return o.order.auxPrice;
    }

    /// Whether `s` is a status update of this order: same permanent id, or,
    /// when the permanent id is unknown, the same order id and client id.
    ///
    /// Here an id of 0 counts as unknown. This is not documented by IB (0 is
    /// only the default value in IB's clients), but without it distinct
    /// orders that both carry 0 (e.g. orders entered in TWS have order id 0)
    /// would be merged into one.
    fn matches(o: *const Order, s: proto.OrderStatus) bool {
        if (nonZero(i64, s.permId)) |status_perm| {
            if (nonZero(i64, o.order.permId)) |perm| return perm == status_perm;
        }
        const id = nonZero(i32, s.orderId) orelse return false;
        if (id != o.order_id) return false;
        const a = s.clientId orelse return true;
        const b = o.order.clientId orelse return true;
        return a == b;
    }

    /// Whether both describe the same order. Ids of 0 count as unknown, as in
    /// `matches`.
    fn sameOrder(a: *const Order, b: *const Order) bool {
        if (nonZero(i64, a.order.permId)) |pa| {
            if (nonZero(i64, b.order.permId)) |pb| return pa == pb;
        }
        if (a.order_id == 0 or a.order_id != b.order_id) return false;
        return (a.order.clientId orelse 0) == (b.order.clientId orelse 0);
    }
};

/// Collects `OpenOrder` and `OrderStatus` messages into one `Order` per
/// order. Messages may come in any order; a later open order message
/// replaces an earlier one of the same order and the latest status wins.
pub const Builder = struct {
    gpa: Allocator,
    orders: std.ArrayList(Order) = .empty,
    statuses: std.ArrayList(proto.OrderStatus) = .empty,

    /// Creates an empty builder allocating with `gpa`.
    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    /// Frees everything not yet taken by `finish`.
    pub fn deinit(b: *Builder) void {
        for (b.orders.items) |*o| o.deinit(b.gpa);
        b.orders.deinit(b.gpa);
        for (b.statuses.items) |*s| s.deinit(b.gpa);
        b.statuses.deinit(b.gpa);
        b.* = undefined;
    }

    /// Adds a copy of an order (open or completed).
    pub fn addOrder(b: *Builder, order: Order) Allocator.Error!void {
        var o = order;
        for (b.orders.items) |*existing| {
            if (existing.sameOrder(&o)) {
                existing.deinit(b.gpa);
                existing.* = o;
                return;
            }
        }
        b.orders.append(b.gpa, o) catch |err| {
            o.deinit(b.gpa);
            return err;
        };
    }

    /// Adds a copy of a status update.
    pub fn addStatus(b: *Builder, s: proto.OrderStatus) Allocator.Error!void {
        try b.statuses.ensureUnusedCapacity(b.gpa, 1);
        b.statuses.appendAssumeCapacity(try s.dupe(b.gpa));
    }

    /// Attaches the latest status to each order and returns the orders,
    /// owned by the caller (free each with `Order.deinit`, then the slice).
    /// Status updates of orders that were not reported are dropped. The
    /// builder is empty afterwards.
    pub fn finish(b: *Builder) Allocator.Error![]Order {
        for (b.statuses.items) |*s| {
            for (b.orders.items) |*o| {
                if (o.matches(s.*)) {
                    if (o.status) |*old| old.deinit(b.gpa);
                    o.status = s.*;
                    break;
                }
            } else {
                log.debug("dropping status of unknown order {?d} (perm id {?d})", .{ s.orderId, s.permId });
                s.deinit(b.gpa);
            }
        }
        b.statuses.clearRetainingCapacity();
        return b.orders.toOwnedSlice(b.gpa);
    }
};

/// Treats 0 as an unknown id; used only for matching (see `Order.matches`).
fn nonZero(comptime T: type, value: ?T) ?T {
    const v = value orelse return null;
    return if (v == 0) null else v;
}

/// Quantities are decimal numbers sent as text; empty means not set.
fn parseDecimal(s: ?[]const u8) ?f64 {
    const text = s orelse return null;
    if (text.len == 0) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "status texts are parsed" {
    try testing.expectEqual(Status.pre_submitted, Status.parse("PreSubmitted"));
    try testing.expectEqual(Status.filled, Status.parse("Filled"));
    try testing.expectEqual(Status.unknown, Status.parse("Something new"));
    try testing.expect(Status.submitted.isActive());
    try testing.expect(!Status.cancelled.isActive());
    try testing.expectEqual(@as(?Action, .sell_short), Action.fromCode("SSHORT"));
    try testing.expectEqual(@as(?Action, null), Action.fromCode("X"));
}

test "statuses are attached to their orders in any message order" {
    const gpa = testing.allocator;
    var b: Builder = .init(gpa);
    defer b.deinit();

    // Status before its open order; matched by order id and client id.
    try b.addStatus(.{ .orderId = 7, .clientId = 1, .status = "PreSubmitted", .filled = "0", .remaining = "100" });
    try b.addOrder(try Order.fromOpenOrder(gpa, .{
        .orderId = 7,
        .contract = .{ .conId = 265598, .symbol = "AAPL", .secType = "STK" },
        .order = .{ .clientId = 1, .orderId = 7, .action = "BUY", .totalQuantity = "100", .orderType = "LMT", .lmtPrice = 180, .tif = "DAY" },
        .orderState = .{ .status = "PreSubmitted" },
    }));
    // Two TWS orders with order id 0, told apart by the permanent id.
    try b.addOrder(try Order.fromOpenOrder(gpa, .{ .orderId = 0, .order = .{ .clientId = 0, .permId = 111, .action = "SELL", .totalQuantity = "5" } }));
    try b.addOrder(try Order.fromOpenOrder(gpa, .{ .orderId = 0, .order = .{ .clientId = 0, .permId = 222, .action = "SELL", .totalQuantity = "6" } }));
    try b.addStatus(.{ .orderId = 0, .permId = 222, .status = "Submitted", .filled = "1", .remaining = "5", .avgFillPrice = 10.5 });
    try b.addStatus(.{ .orderId = 0, .permId = 111, .status = "Submitted", .filled = "0", .remaining = "5" });
    // A later status of the same order replaces the earlier one.
    try b.addStatus(.{ .orderId = 0, .permId = 222, .status = "Submitted", .filled = "2", .remaining = "4", .avgFillPrice = 10.6 });
    // A repeated open order message replaces the order but keeps statuses.
    try b.addOrder(try Order.fromOpenOrder(gpa, .{ .orderId = 0, .order = .{ .clientId = 0, .permId = 111, .action = "SELL", .totalQuantity = "5", .lmtPrice = 12 } }));
    // A status of an order that was not reported is dropped.
    try b.addStatus(.{ .orderId = 99, .permId = 999, .status = "Filled" });

    const orders = try b.finish();
    defer {
        for (orders) |*o| o.deinit(gpa);
        gpa.free(orders);
    }
    try testing.expectEqual(@as(usize, 3), orders.len);

    const aapl = &orders[0];
    try testing.expectEqual(@as(i32, 7), aapl.order_id);
    try testing.expectEqual(Status.pre_submitted, aapl.statusKind());
    try testing.expectEqual(@as(?Action, .buy), aapl.action());
    try testing.expectEqual(@as(?f64, 100), aapl.totalQuantity());
    try testing.expectEqual(@as(?f64, 100), aapl.remainingQuantity());
    try testing.expectEqual(@as(?f64, 180), aapl.limitPrice());
    try testing.expectEqual(@as(?f64, null), aapl.auxPrice());
    try testing.expectEqualStrings("LMT", aapl.orderType().?);

    try testing.expectEqual(@as(?i64, 111), orders[1].permId());
    try testing.expectEqual(@as(?f64, 12), orders[1].limitPrice());
    try testing.expectEqual(@as(?f64, 0), orders[1].filledQuantity());

    try testing.expectEqual(@as(?i64, 222), orders[2].permId());
    try testing.expectEqual(@as(?f64, 2), orders[2].filledQuantity());
    try testing.expectEqual(@as(?f64, 10.6), orders[2].avgFillPrice());
    try testing.expectEqual(Status.submitted, orders[2].statusKind());
}

test "completed orders take the status from their state" {
    const gpa = testing.allocator;
    var o = try Order.fromCompletedOrder(gpa, .{
        .contract = .{ .symbol = "MSFT" },
        .order = .{ .permId = 5, .action = "SELL", .totalQuantity = "10", .filledQuantity = "10" },
        .orderState = .{ .status = "Filled", .completedTime = "20261118 15:30:00 Europe/Prague", .completedStatus = "Filled Size: 10" },
    });
    defer o.deinit(gpa);
    try testing.expectEqual(Status.filled, o.statusKind());
    try testing.expectEqual(@as(?f64, 10), o.filledQuantity());
    try testing.expectEqual(@as(?f64, null), o.remainingQuantity());
    try testing.expectEqualStrings("MSFT", o.contract.symbol.?);
}
