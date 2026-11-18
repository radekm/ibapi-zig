//! Market data snapshots: types and assembly of ticks into a `Quote`.

const std = @import("std");
const proto = @import("ibapi_proto");

/// Which market data TWS should send. Set with `Client.Options.market_data_type`.
pub const MarketDataType = enum(i32) {
    /// Real-time data; needs a market data subscription and fails outside
    /// trading hours for some instruments.
    live = 1,
    /// Real-time data while the market is open, otherwise the last values
    /// recorded at the close. Needs the same subscription as `live`.
    frozen = 2,
    /// Types the library never requests but TWS may report (delayed data).
    _,
};

/// Values computed by the TWS option model for one source price.
/// Each field is null when TWS did not compute it.
pub const OptionComputation = struct {
    implied_vol: ?f64 = null,
    delta: ?f64 = null,
    gamma: ?f64 = null,
    vega: ?f64 = null,
    theta: ?f64 = null,
    /// Option price the computation is based on (for `model`: the model price).
    option_price: ?f64 = null,
    /// Present value of dividends expected until expiration.
    pv_dividend: ?f64 = null,
    /// Price of the underlying used in the computation.
    underlying_price: ?f64 = null,

    fn fromProto(m: proto.TickOptionComputation) OptionComputation {
        // TWS marks values it did not compute with -1 (prices, volatility)
        // or -2 (greeks).
        return .{
            .implied_vol = unless(m.impliedVol, -1),
            .delta = unless(m.delta, -2),
            .gamma = unless(m.gamma, -2),
            .vega = unless(m.vega, -2),
            .theta = unless(m.theta, -2),
            .option_price = unless(m.optPrice, -1),
            .pv_dividend = unless(m.pvDividend, -1),
            .underlying_price = unless(m.undPrice, -1),
        };
    }
};

/// A snapshot of the market data of one contract. Fields TWS did not send
/// are null. Sizes are in shares or contracts.
pub const Quote = struct {
    /// The kind of data TWS actually sent (live or frozen).
    data_type: ?MarketDataType = null,

    bid: ?f64 = null,
    bid_size: ?f64 = null,
    ask: ?f64 = null,
    ask_size: ?f64 = null,
    last: ?f64 = null,
    last_size: ?f64 = null,
    /// Time of the last trade, seconds since the Unix epoch.
    last_timestamp: ?i64 = null,
    open: ?f64 = null,
    high: ?f64 = null,
    low: ?f64 = null,
    /// Close of the previous trading day.
    close: ?f64 = null,
    volume: ?f64 = null,

    /// Option model values based on the bid, ask and last price of the
    /// option, and on IB's own volatility model (`model`). Null for
    /// non-options or when TWS sent nothing.
    bid_computation: ?OptionComputation = null,
    ask_computation: ?OptionComputation = null,
    last_computation: ?OptionComputation = null,
    model_computation: ?OptionComputation = null,

    /// Midpoint of bid and ask, if both are known.
    pub fn mid(q: Quote) ?f64 {
        const b = q.bid orelse return null;
        const a = q.ask orelse return null;
        return (b + a) / 2;
    }
};

/// TWS tick type ids used by snapshots.
pub const TickType = enum(i32) {
    bid_size = 0,
    bid = 1,
    ask = 2,
    ask_size = 3,
    last = 4,
    last_size = 5,
    high = 6,
    low = 7,
    volume = 8,
    close = 9,
    bid_option_computation = 10,
    ask_option_computation = 11,
    last_option_computation = 12,
    model_option_computation = 13,
    open = 14,
    last_timestamp = 45,
    _,
};

/// Updates `q` with a price tick (and the size it may carry).
pub fn applyPrice(q: *Quote, m: proto.TickPrice) void {
    const price = unless(m.price, -1);
    const size = parseSize(m.size);
    switch (@as(TickType, @fromBackingInt(@intCast(m.tickType orelse return)))) {
        .bid => {
            q.bid = price;
            if (size) |s| q.bid_size = s;
        },
        .ask => {
            q.ask = price;
            if (size) |s| q.ask_size = s;
        },
        .last => {
            q.last = price;
            if (size) |s| q.last_size = s;
        },
        .high => q.high = price,
        .low => q.low = price,
        .close => q.close = price,
        .open => q.open = price,
        else => {},
    }
}

/// Updates `q` with a size tick.
pub fn applySize(q: *Quote, m: proto.TickSize) void {
    const size = parseSize(m.size);
    switch (@as(TickType, @fromBackingInt(@intCast(m.tickType orelse return)))) {
        .bid_size => q.bid_size = size,
        .ask_size => q.ask_size = size,
        .last_size => q.last_size = size,
        .volume => q.volume = size,
        else => {},
    }
}

/// Updates `q` with a string tick (last trade time).
pub fn applyString(q: *Quote, m: proto.TickString) void {
    switch (@as(TickType, @fromBackingInt(@intCast(m.tickType orelse return)))) {
        .last_timestamp => q.last_timestamp = std.fmt.parseInt(i64, m.value orelse return, 10) catch null,
        else => {},
    }
}

/// Updates `q` with an option model computation.
pub fn applyOptionComputation(q: *Quote, m: proto.TickOptionComputation) void {
    const value = OptionComputation.fromProto(m);
    switch (@as(TickType, @fromBackingInt(@intCast(m.tickType orelse return)))) {
        .bid_option_computation => q.bid_computation = value,
        .ask_option_computation => q.ask_computation = value,
        .last_option_computation => q.last_computation = value,
        .model_option_computation => q.model_computation = value,
        else => {},
    }
}

fn unless(value: ?f64, missing: f64) ?f64 {
    const v = value orelse return null;
    return if (v == missing) null else v;
}

fn parseSize(s: ?[]const u8) ?f64 {
    const text = s orelse return null;
    if (text.len == 0) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

const testing = std.testing;

test "price ticks fill the quote, -1 means no price" {
    var q: Quote = .{};
    applyPrice(&q, .{ .tickType = 1, .price = 189.5, .size = "300" });
    applyPrice(&q, .{ .tickType = 2, .price = 189.6, .size = "200" });
    applyPrice(&q, .{ .tickType = 4, .price = -1 });
    applyPrice(&q, .{ .tickType = 9, .price = 188.1 });
    applySize(&q, .{ .tickType = 8, .size = "1234567" });
    applyString(&q, .{ .tickType = 45, .value = "1763478840" });
    applyPrice(&q, .{ .tickType = 99, .price = 1 }); // unknown ticks are ignored

    try testing.expectEqual(@as(?f64, 189.5), q.bid);
    try testing.expectEqual(@as(?f64, 300), q.bid_size);
    try testing.expectEqual(@as(?f64, 200), q.ask_size);
    try testing.expectEqual(@as(?f64, null), q.last);
    try testing.expectEqual(@as(?f64, 188.1), q.close);
    try testing.expectEqual(@as(?f64, 1234567), q.volume);
    try testing.expectEqual(@as(?i64, 1763478840), q.last_timestamp);
    try testing.expectApproxEqAbs(@as(f64, 189.55), q.mid().?, 1e-9);
}

test "option computations drop values TWS did not compute" {
    var q: Quote = .{};
    applyOptionComputation(&q, .{
        .tickType = 13,
        .impliedVol = 0.25,
        .delta = 0.52,
        .gamma = -2,
        .vega = 0.31,
        .theta = -0.04,
        .optPrice = 7.85,
        .pvDividend = -1,
        .undPrice = 189.55,
    });
    const m = q.model_computation.?;
    try testing.expectEqual(@as(?f64, 0.25), m.implied_vol);
    try testing.expectEqual(@as(?f64, null), m.gamma);
    try testing.expectEqual(@as(?f64, null), m.pv_dividend);
    try testing.expectEqual(@as(?f64, 189.55), m.underlying_price);
    try testing.expectEqual(@as(?OptionComputation, null), q.bid_computation);
}
