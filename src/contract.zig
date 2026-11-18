//! Describing contracts (instruments) for requests.

const std = @import("std");
const proto = @import("ibapi_proto");

/// Security type of a contract.
pub const SecType = enum {
    stock,
    option,
    future,
    future_option,
    index,
    forex,
    bond,
    cfd,
    warrant,
    commodity,
    fund,
    crypto,
    combo,

    /// The code TWS uses for this security type.
    pub fn code(t: SecType) []const u8 {
        return switch (t) {
            .stock => "STK",
            .option => "OPT",
            .future => "FUT",
            .future_option => "FOP",
            .index => "IND",
            .forex => "CASH",
            .bond => "BOND",
            .cfd => "CFD",
            .warrant => "WAR",
            .commodity => "CMDTY",
            .fund => "FUND",
            .crypto => "CRYPTO",
            .combo => "BAG",
        };
    }

    /// Parses a TWS code such as "STK"; returns null for unknown codes.
    pub fn fromCode(s: []const u8) ?SecType {
        inline for (@typeInfo(SecType).@"enum".field_names) |name| {
            const t = @field(SecType, name);
            if (std.mem.eql(u8, s, t.code())) return t;
        }
        return null;
    }
};

/// Right of an option.
pub const Right = enum {
    call,
    put,

    /// The code TWS uses for this right.
    pub fn code(r: Right) []const u8 {
        return switch (r) {
            .call => "C",
            .put => "P",
        };
    }

    /// Parses "C", "CALL", "P" or "PUT"; returns null otherwise.
    pub fn fromCode(s: []const u8) ?Right {
        if (std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "CALL")) return .call;
        if (std.mem.eql(u8, s, "P") or std.mem.eql(u8, s, "PUT")) return .put;
        return null;
    }
};

/// A (possibly partial) contract description. Fields left `null` are not
/// sent, so a query can match many contracts, e.g. all options of a symbol.
/// Strings are borrowed for the duration of the request.
pub const Query = struct {
    /// IB contract id; identifies a contract uniquely on its own.
    con_id: ?i32 = null,
    /// Symbol of the instrument or of the underlying, e.g. "AAPL".
    symbol: ?[]const u8 = null,
    sec_type: ?SecType = null,
    /// Destination exchange, e.g. "SMART", "CME".
    exchange: ?[]const u8 = null,
    /// Primary listing exchange, used to disambiguate SMART-routed stocks.
    primary_exchange: ?[]const u8 = null,
    /// Currency, e.g. "USD".
    currency: ?[]const u8 = null,
    /// Last trade date (YYYYMMDD) or contract month (YYYYMM) of derivatives.
    expiry: ?[]const u8 = null,
    strike: ?f64 = null,
    right: ?Right = null,
    multiplier: ?f64 = null,
    /// Symbol at the primary exchange; for options the OCC symbol.
    local_symbol: ?[]const u8 = null,
    trading_class: ?[]const u8 = null,
    /// Kind of `sec_id`, e.g. "ISIN", "CUSIP", "FIGI".
    sec_id_type: ?[]const u8 = null,
    sec_id: ?[]const u8 = null,
    /// Also match expired derivatives.
    include_expired: bool = false,

    /// A stock routed through SMART.
    pub fn stock(symbol: []const u8, currency: []const u8) Query {
        return .{ .symbol = symbol, .sec_type = .stock, .exchange = "SMART", .currency = currency };
    }

    /// An option on `symbol`. Leave `expiry`, `strike` or `right` null to
    /// match all options with the other parameters.
    pub fn option(symbol: []const u8, currency: []const u8, expiry: ?[]const u8, strike: ?f64, right: ?Right) Query {
        return .{
            .symbol = symbol,
            .sec_type = .option,
            .exchange = "SMART",
            .currency = currency,
            .expiry = expiry,
            .strike = strike,
            .right = right,
        };
    }

    /// A future on `exchange`; leave `expiry` null to match all expirations.
    pub fn future(symbol: []const u8, exchange: []const u8, currency: []const u8, expiry: ?[]const u8) Query {
        return .{ .symbol = symbol, .sec_type = .future, .exchange = exchange, .currency = currency, .expiry = expiry };
    }

    /// An index, e.g. `index("SPX", "CBOE", "USD")`.
    pub fn index(symbol: []const u8, exchange: []const u8, currency: []const u8) Query {
        return .{ .symbol = symbol, .sec_type = .index, .exchange = exchange, .currency = currency };
    }

    /// A currency pair on IDEALPRO, e.g. `forex("EUR", "USD")` for EUR.USD.
    pub fn forex(base: []const u8, quote: []const u8) Query {
        return .{ .symbol = base, .sec_type = .forex, .exchange = "IDEALPRO", .currency = quote };
    }

    /// A contract identified by its IB contract id, e.g. from an earlier lookup.
    pub fn byConId(con_id: i32, exchange: ?[]const u8) Query {
        return .{ .con_id = con_id, .exchange = exchange };
    }

    /// The protobuf representation. Slices in the result borrow from `q`.
    pub fn toProto(q: Query) proto.Contract {
        return .{
            .conId = q.con_id,
            .symbol = q.symbol,
            .secType = if (q.sec_type) |t| t.code() else null,
            .lastTradeDateOrContractMonth = q.expiry,
            .strike = q.strike,
            .right = if (q.right) |r| r.code() else null,
            .multiplier = q.multiplier,
            .exchange = q.exchange,
            .primaryExch = q.primary_exchange,
            .currency = q.currency,
            .localSymbol = q.local_symbol,
            .tradingClass = q.trading_class,
            .secIdType = q.sec_id_type,
            .secId = q.sec_id,
            .includeExpired = if (q.include_expired) true else null,
        };
    }
};

/// The underlying of an option chain, for `Client.optionChainParams`.
pub const Underlying = struct {
    /// Symbol of the underlying, e.g. "AAPL" or "SPX".
    symbol: []const u8,
    /// Security type of the underlying: stock, index or future.
    sec_type: SecType = .stock,
    /// IB contract id of the underlying (from `Client.contractDetails`); required by TWS.
    con_id: i32,
    /// For options on futures: the exchange of the options. Null for all exchanges.
    fut_fop_exchange: ?[]const u8 = null,
};

const testing = std.testing;

test "security type codes round-trip" {
    inline for (@typeInfo(SecType).@"enum".field_names) |name| {
        const t = @field(SecType, name);
        try testing.expectEqual(@as(?SecType, t), SecType.fromCode(t.code()));
    }
    try testing.expectEqual(@as(?SecType, null), SecType.fromCode("XYZ"));
    try testing.expectEqual(@as(?Right, .put), Right.fromCode("PUT"));
}

test "a query sends only the fields that are set" {
    const p = Query.option("AAPL", "USD", "20261218", 200, .call).toProto();
    try testing.expectEqualStrings("OPT", p.secType.?);
    try testing.expectEqualStrings("C", p.right.?);
    try testing.expectEqual(@as(?f64, 200), p.strike);
    try testing.expectEqual(@as(?i32, null), p.conId);
    try testing.expectEqual(@as(?bool, null), p.includeExpired);

    const all = Query.option("AAPL", "USD", null, null, null).toProto();
    try testing.expectEqual(@as(?[]const u8, null), all.lastTradeDateOrContractMonth);
    try testing.expectEqual(@as(?f64, null), all.strike);
}
