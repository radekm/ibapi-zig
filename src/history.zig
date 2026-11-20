//! Historical bars (OHLC): bar types, request parameters and the helpers
//! `Client.minuteBars` and `Client.dailyBars` use to build requests and to
//! read the answers.
//!
//! Only 1-minute and 1-day bars are offered; larger bars can be aggregated
//! from them. Requests are always one-off: `keepUpToDate` (a subscription)
//! is never sent.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const epoch = std.time.epoch;
const proto = @import("ibapi_proto");

/// A calendar day: the number of days since 1970-01-01. Convert to a date
/// with `calculateYearDay().calculateMonthDay()`, create with `day`.
pub const Day = epoch.EpochDay;

/// Returns the `Day` of a date, e.g. `day(2025, 1, 2)`. Fails for dates
/// that do not exist and for dates before 1970-01-01.
pub fn day(year: u16, month: u8, day_of_month: u8) error{InvalidDate}!Day {
    if (year < epoch.epoch_year or month < 1 or month > 12 or day_of_month < 1) return error.InvalidDate;
    const m: epoch.Month = @fromBackingInt(@intCast(month));
    if (day_of_month > epoch.getDaysInMonth(year, m)) return error.InvalidDate;
    // Days from the civil date (proleptic Gregorian calendar), with years
    // starting in March so that the leap day is the last day of a year.
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day_of_month - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return .{ .day = @intCast(days) };
}

/// What the bars are built from (`whatToShow`).
pub const WhatToShow = enum {
    /// Trades; the only kind with volume, WAP and trade count.
    trades,
    /// Midpoint of bid and ask.
    midpoint,
    /// Bid prices.
    bid,
    /// Ask prices.
    ask,
    /// Bid and ask in one bar. **The OHLC fields have a special meaning**:
    /// `open` is the time-average bid, `high` the highest ask, `low` the
    /// lowest bid and `close` the time-average ask. IB counts these
    /// requests twice towards its pacing limits.
    bid_ask,
    /// Trades adjusted for splits and dividends. IB requires the request to
    /// end now, so `end` / `last` must be null and a `minuteBars` range at
    /// most one day (later chunks carry an end time).
    adjusted_last,
    /// Historical volatility of the contract.
    historical_volatility,
    /// Implied volatility of the options on the contract.
    option_implied_volatility,

    /// The value sent to TWS.
    pub fn code(w: WhatToShow) []const u8 {
        return switch (w) {
            .trades => "TRADES",
            .midpoint => "MIDPOINT",
            .bid => "BID",
            .ask => "ASK",
            .bid_ask => "BID_ASK",
            .adjusted_last => "ADJUSTED_LAST",
            .historical_volatility => "HISTORICAL_VOLATILITY",
            .option_implied_volatility => "OPTION_IMPLIED_VOLATILITY",
        };
    }
};

/// Parameters of `Client.minuteBars`.
pub const MinuteBarsParams = struct {
    /// Bars starting at or after this instant are returned.
    start: Io.Timestamp,
    /// Bars starting before this instant are returned; null means now, in
    /// which case the current, still unfinished bar may be included.
    end: ?Io.Timestamp = null,
    what_to_show: WhatToShow = .trades,
    /// Only regular trading hours.
    use_rth: bool = true,
};

/// Parameters of `Client.dailyBars`.
pub const DailyBarsParams = struct {
    /// First trading day returned (inclusive).
    first: Day,
    /// Last trading day returned (inclusive); null means today, in which case
    /// today's unfinished bar may be included.
    last: ?Day = null,
    what_to_show: WhatToShow = .trades,
    /// Only regular trading hours.
    use_rth: bool = true,
};

/// One 1-minute bar.
///
/// IB documents no special values for bars; fields absent from the message
/// are null. For `WhatToShow.bid_ask` the OHLC fields have a special
/// meaning, see there.
pub const MinuteBar = struct {
    /// Start of the bar (UTC instant, whole seconds).
    time: Io.Timestamp,
    open: ?f64,
    high: ?f64,
    low: ?f64,
    close: ?f64,
    /// Traded volume; only for `WhatToShow.trades`.
    volume: ?f64,
    /// Volume-weighted average price; only for `WhatToShow.trades`.
    wap: ?f64,
    /// Number of trades; only for `WhatToShow.trades`.
    count: ?i32,

    /// Converts a bar received with `formatDate = 2` (epoch seconds).
    pub fn fromProto(b: proto.HistoricalDataBar) error{UnexpectedResponse}!MinuteBar {
        const text = b.date orelse return error.UnexpectedResponse;
        const secs = std.fmt.parseInt(i64, text, 10) catch return error.UnexpectedResponse;
        return .{
            .time = fromSeconds(secs),
            .open = b.open,
            .high = b.high,
            .low = b.low,
            .close = b.close,
            .volume = parseDecimal(b.volume),
            .wap = parseDecimal(b.WAP),
            .count = b.barCount,
        };
    }

    fn key(b: MinuteBar) i96 {
        return b.time.nanoseconds;
    }
};

/// One 1-day bar.
///
/// IB documents no special values for bars; fields absent from the message
/// are null. For `WhatToShow.bid_ask` the OHLC fields have a special
/// meaning, see there.
pub const DailyBar = struct {
    /// Trading day of the bar, as dated by the exchange (no time zone).
    day: Day,
    open: ?f64,
    high: ?f64,
    low: ?f64,
    close: ?f64,
    /// Traded volume; only for `WhatToShow.trades`.
    volume: ?f64,
    /// Volume-weighted average price; only for `WhatToShow.trades`.
    wap: ?f64,
    /// Number of trades; only for `WhatToShow.trades`.
    count: ?i32,

    /// Converts a bar whose date is `yyyyMMdd` (the only format of day bars).
    pub fn fromProto(b: proto.HistoricalDataBar) error{UnexpectedResponse}!DailyBar {
        return .{
            .day = parseDay(b.date orelse "") catch return error.UnexpectedResponse,
            .open = b.open,
            .high = b.high,
            .low = b.low,
            .close = b.close,
            .volume = parseDecimal(b.volume),
            .wap = parseDecimal(b.WAP),
            .count = b.barCount,
        };
    }

    fn key(b: DailyBar) i96 {
        return b.day.day;
    }
};

/// Bars returned by `Client.minuteBars` / `Client.dailyBars`, oldest first,
/// allocated with `gpa`.
pub fn Bars(comptime T: type) type {
    return struct {
        gpa: Allocator,
        items: []T,

        /// Frees the bars.
        pub fn deinit(l: *@This()) void {
            l.gpa.free(l.items);
            l.* = undefined;
        }
    };
}

/// Result of `Client.minuteBars`.
pub const MinuteBars = Bars(MinuteBar);
/// Result of `Client.dailyBars`.
pub const DailyBars = Bars(DailyBar);

// ---------------------------------------------------------------------------
// Helpers used by the client

/// Largest duration of one 1-minute request (IB's step sizes: 1 day of
/// 1-minute bars per request).
pub const max_minute_chunk_seconds: i64 = 86400;
/// Smallest duration sent with 1-minute bars.
pub const min_minute_chunk_seconds: i64 = 60;

/// Bar size strings sent to TWS.
pub const bar_size_minute = "1 min";
pub const bar_size_day = "1 day";

/// `formatDate` values: 1 = text (day bars are always `yyyyMMdd`),
/// 2 = epoch seconds.
pub const format_date_text: i32 = 1;
pub const format_date_epoch: i32 = 2;

/// Whether TWS error 162 ("Historical Market Data Service error") says that
/// the query returned no data, which is not a failure but an empty result.
/// The code also covers real failures (e.g. pacing violations), so the text
/// has to be checked.
pub fn isNoData(code: i32, message: []const u8) bool {
    return code == 162 and std.ascii.findIgnoreCase(message, "returned no data") != null;
}

/// Converts whole seconds since the Unix epoch to a timestamp.
pub fn fromSeconds(secs: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
}

/// Seconds since the epoch, rounded up.
pub fn ceilSeconds(t: Io.Timestamp) i64 {
    return @intCast(-@divFloor(-t.nanoseconds, std.time.ns_per_s));
}

/// Seconds since the epoch, rounded down.
pub fn floorSeconds(t: Io.Timestamp) i64 {
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
}

/// Formats `secs` (≥ 0) as the UTC `endDateTime` `YYYYMMDD-HH:mm:ss`.
pub fn formatUtc(buf: *[17]u8, secs: u64) []const u8 {
    const es: epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Formats a duration string such as `3600 S`, `30 D` or `2 Y`.
pub fn formatDuration(buf: *[24]u8, amount: u64, unit: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {c}", .{ amount, unit }) catch unreachable;
}

/// Duration of a 1-day request covering `days` calendar days: `N D` up to
/// one year, whole years beyond.
pub fn dailyDuration(buf: *[24]u8, days: u64) []const u8 {
    if (days <= 365) return formatDuration(buf, @max(days, 1), 'D');
    return formatDuration(buf, (days + 364) / 365, 'Y');
}

/// Parses `yyyyMMdd`.
pub fn parseDay(text: []const u8) error{InvalidDate}!Day {
    if (text.len != 8) return error.InvalidDate;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidDate;
    const y = std.fmt.parseInt(u16, text[0..4], 10) catch return error.InvalidDate;
    const m = std.fmt.parseInt(u8, text[4..6], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(u8, text[6..8], 10) catch return error.InvalidDate;
    return day(y, m, d);
}

/// Sorts bars oldest first and removes bars with the same time (chunks of
/// a request may overlap).
pub fn sortUnique(comptime T: type, items: []T) []T {
    const Ctx = struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return a.key() < b.key();
        }
    };
    std.sort.pdq(T, items, {}, Ctx.lessThan);
    var n: usize = 0;
    for (items) |b| {
        if (n > 0 and items[n - 1].key() == b.key()) continue;
        items[n] = b;
        n += 1;
    }
    return items[0..n];
}

/// Volumes and prices sent as decimal text; empty means not set.
fn parseDecimal(s: ?[]const u8) ?f64 {
    const text = s orelse return null;
    if (text.len == 0) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "dates are converted to days" {
    try testing.expectEqual(@as(u47, 0), (try day(1970, 1, 1)).day);
    try testing.expectEqual(@as(u47, 20090), (try day(2025, 1, 2)).day);
    try testing.expectEqual(@as(u47, 11016), (try day(2000, 2, 29)).day);
    try testing.expectError(error.InvalidDate, day(2025, 2, 29));
    try testing.expectError(error.InvalidDate, day(1969, 12, 31));
    try testing.expectError(error.InvalidDate, day(2025, 13, 1));
    try testing.expectError(error.InvalidDate, day(2025, 4, 0));

    // Round trip through std.
    const d = try day(2024, 12, 31);
    const yd = d.calculateYearDay();
    const md = yd.calculateMonthDay();
    try testing.expectEqual(@as(u16, 2024), yd.year);
    try testing.expectEqual(epoch.Month.dec, md.month);
    try testing.expectEqual(@as(u5, 30), md.day_index);
}

test "day bar dates are parsed" {
    try testing.expectEqual((try day(2025, 11, 19)).day, (try parseDay("20251119")).day);
    try testing.expectError(error.InvalidDate, parseDay("2025111"));
    try testing.expectError(error.InvalidDate, parseDay("2025-1-19"));
    try testing.expectError(error.InvalidDate, parseDay("20251131"));
}

test "request strings" {
    var buf: [17]u8 = undefined;
    try testing.expectEqualStrings("20251120-15:30:05", formatUtc(&buf, 1763652605));
    try testing.expectEqualStrings("19700101-00:00:00", formatUtc(&buf, 0));

    var dbuf: [24]u8 = undefined;
    try testing.expectEqualStrings("3600 S", formatDuration(&dbuf, 3600, 'S'));
    try testing.expectEqualStrings("1 D", dailyDuration(&dbuf, 0));
    try testing.expectEqualStrings("365 D", dailyDuration(&dbuf, 365));
    try testing.expectEqualStrings("2 Y", dailyDuration(&dbuf, 366));
    try testing.expectEqualStrings("2 Y", dailyDuration(&dbuf, 730));
    try testing.expectEqualStrings("3 Y", dailyDuration(&dbuf, 731));

    try testing.expectEqualStrings("BID_ASK", WhatToShow.bid_ask.code());
}

test "seconds are rounded" {
    const t: Io.Timestamp = .fromNanoseconds(10 * std.time.ns_per_s + 1);
    try testing.expectEqual(@as(i64, 11), ceilSeconds(t));
    try testing.expectEqual(@as(i64, 10), floorSeconds(t));
    try testing.expectEqual(@as(i64, 10), ceilSeconds(fromSeconds(10)));
    const neg: Io.Timestamp = .fromNanoseconds(-1);
    try testing.expectEqual(@as(i64, 0), ceilSeconds(neg));
    try testing.expectEqual(@as(i64, -1), floorSeconds(neg));
}

test "bars are converted from protobuf" {
    const m = try MinuteBar.fromProto(.{
        .date = "1763652600",
        .open = 1.5,
        .high = 2,
        .low = 1,
        .close = 1.75,
        .volume = "1234.5",
        .WAP = "1.6",
        .barCount = 7,
    });
    try testing.expectEqual(@as(i64, 1763652600), floorSeconds(m.time));
    try testing.expectEqual(@as(?f64, 1234.5), m.volume);
    try testing.expectEqual(@as(?f64, 1.6), m.wap);
    try testing.expectEqual(@as(?i32, 7), m.count);

    const empty = try MinuteBar.fromProto(.{ .date = "0", .volume = "" });
    try testing.expectEqual(@as(?f64, null), empty.volume);
    try testing.expectEqual(@as(?f64, null), empty.open);
    try testing.expectError(error.UnexpectedResponse, MinuteBar.fromProto(.{ .date = "20251120 15:30:00 US/Eastern" }));
    try testing.expectError(error.UnexpectedResponse, MinuteBar.fromProto(.{}));

    const d = try DailyBar.fromProto(.{ .date = "20251119", .close = 10, .volume = "100" });
    try testing.expectEqual((try day(2025, 11, 19)).day, d.day.day);
    try testing.expectEqual(@as(?f64, 100), d.volume);
    try testing.expectError(error.UnexpectedResponse, DailyBar.fromProto(.{ .date = "1763652600" }));
}

test "no-data errors are recognised" {
    try testing.expect(isNoData(162, "Historical Market Data Service error message:HMDS query returned no data: AAPL@SMART Trades"));
    try testing.expect(!isNoData(162, "Historical Market Data Service error message:Historical data request pacing violation"));
    try testing.expect(!isNoData(200, "returned no data"));
}

test "bars are sorted and deduplicated" {
    var items = [_]MinuteBar{
        .{ .time = fromSeconds(120), .open = 3, .high = null, .low = null, .close = null, .volume = null, .wap = null, .count = null },
        .{ .time = fromSeconds(60), .open = 2, .high = null, .low = null, .close = null, .volume = null, .wap = null, .count = null },
        .{ .time = fromSeconds(120), .open = 3, .high = null, .low = null, .close = null, .volume = null, .wap = null, .count = null },
        .{ .time = fromSeconds(0), .open = 1, .high = null, .low = null, .close = null, .volume = null, .wap = null, .count = null },
    };
    const out = sortUnique(MinuteBar, &items);
    try testing.expectEqual(@as(usize, 3), out.len);
    for (out, 0..) |b, i| try testing.expectEqual(@as(?f64, @floatFromInt(i + 1)), b.open);
}

// ---------------------------------------------------------------------------
// Tests of `Client.minuteBars` and `Client.dailyBars` against the fake server

const Client = @import("Client.zig");
const FakeServer = @import("FakeServer.zig");
const contract = @import("contract.zig");
const wire = @import("wire.zig");

/// 2025-11-20 00:00:00 UTC.
const test_day_start: i64 = 1763596800;

/// Reads a historical data request and checks the fields every request has.
fn expectBarsRequest(conn: *FakeServer.Conn, bar_size: []const u8, format_date: i32) !proto.HistoricalDataRequest {
    const req = try conn.readRequest();
    try testing.expectEqual(wire.OutMsg.req_historical_data, req.id);
    const q = try req.decode(proto.HistoricalDataRequest, testing.allocator);
    try testing.expectEqualStrings(bar_size, q.barSizeSetting.?);
    try testing.expectEqual(@as(?i32, format_date), q.formatDate);
    try testing.expectEqual(@as(?bool, null), q.keepUpToDate);
    try testing.expectEqualStrings("AAPL", q.contract.?.symbol.?);
    return q;
}

fn sendBars(conn: *FakeServer.Conn, req_id: ?i32, dates: []const []const u8) !void {
    const gpa = testing.allocator;
    var data: proto.HistoricalData = .{ .reqId = req_id };
    defer data.historicalDataBars.deinit(gpa);
    for (dates, 0..) |date, i| {
        const price: f64 = @floatFromInt(100 + i);
        try data.historicalDataBars.append(gpa, .{
            .date = date,
            .open = price,
            .high = price + 1,
            .low = price - 1,
            .close = price,
            .volume = "1500",
            .WAP = "100.25",
            .barCount = 12,
        });
    }
    try conn.send(.historical_data, data);
    try conn.send(.historical_data_end, proto.HistoricalDataEnd{ .reqId = req_id, .startDateStr = "", .endDateStr = "" });
}

fn sendNoData(conn: *FakeServer.Conn, req_id: ?i32) !void {
    try conn.send(.error_message, proto.ErrorMessage{
        .id = req_id,
        .errorCode = 162,
        .errorMsg = "Historical Market Data Service error message:HMDS query returned no data: AAPL@SMART Trades",
    });
}

fn epochText(buf: *[24]u8, secs: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{secs}) catch unreachable;
}

fn serveMinuteBars(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);
    const t15 = test_day_start + 15 * 3600;
    var b: [4][24]u8 = undefined;

    // 1. One hour, answered by one request.
    {
        var q = try expectBarsRequest(conn, "1 min", 2);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("20251120-16:00:00", q.endDateTime.?);
        try testing.expectEqualStrings("3600 S", q.duration.?);
        try testing.expectEqualStrings("TRADES", q.whatToShow.?);
        try testing.expectEqual(@as(?bool, true), q.useRTH);
        try conn.send(.error_message, proto.ErrorMessage{ .id = q.reqId, .errorCode = 2106, .errorMsg = "HMDS data farm connection is OK" });
        // Out of order, with bars outside [start, end).
        try sendBars(conn, q.reqId, &.{
            epochText(&b[0], t15 + 60),
            epochText(&b[1], t15 - 60),
            epochText(&b[2], t15),
            epochText(&b[3], t15 + 3600),
        });
    }
    // 2. 49 hours: three requests walking backwards, overlapping by a bar.
    {
        const end = test_day_start + 49 * 3600;
        var q1 = try expectBarsRequest(conn, "1 min", 2);
        defer q1.deinit(gpa);
        try testing.expectEqualStrings("20251122-01:00:00", q1.endDateTime.?);
        try testing.expectEqualStrings("86400 S", q1.duration.?);
        try testing.expectEqualStrings("MIDPOINT", q1.whatToShow.?);
        try testing.expectEqual(@as(?bool, false), q1.useRTH);
        try sendBars(conn, q1.reqId, &.{ epochText(&b[0], end - 86400), epochText(&b[1], end - 60) });

        var q2 = try expectBarsRequest(conn, "1 min", 2);
        defer q2.deinit(gpa);
        try testing.expectEqualStrings("20251121-01:01:00", q2.endDateTime.?);
        try testing.expectEqualStrings("86400 S", q2.duration.?);
        try sendBars(conn, q2.reqId, &.{ epochText(&b[0], end - 100_000), epochText(&b[1], end - 86400) });

        var q3 = try expectBarsRequest(conn, "1 min", 2);
        defer q3.deinit(gpa);
        try testing.expectEqualStrings("20251120-01:02:00", q3.endDateTime.?);
        try testing.expectEqualStrings("3720 S", q3.duration.?);
        try sendNoData(conn, q3.reqId);
    }
    // 3. A rejection that is not "no data".
    {
        var q = try expectBarsRequest(conn, "1 min", 2);
        defer q.deinit(gpa);
        try conn.send(.error_message, proto.ErrorMessage{
            .id = q.reqId,
            .errorCode = 162,
            .errorMsg = "Historical Market Data Service error message:Historical data request pacing violation",
        });
    }
    // 4. No answer: the client times out and cancels the request.
    {
        var q = try expectBarsRequest(conn, "1 min", 2);
        defer q.deinit(gpa);
        const cancel = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.cancel_historical_data, cancel.id);
        var cq = try cancel.decode(proto.CancelHistoricalData, gpa);
        defer cq.deinit(gpa);
        try testing.expectEqual(q.reqId, cq.reqId);
    }
    try conn.expectClose();
}

test "minute bars: one request, several requests, rejections and timeouts" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveMinuteBars, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();
        const aapl = contract.Query.stock("AAPL", "USD");
        const t15 = test_day_start + 15 * 3600;

        var one = try c.minuteBars(gpa, aapl, .{ .start = fromSeconds(t15), .end = fromSeconds(t15 + 3600) }, .{});
        defer one.deinit();
        try testing.expectEqual(@as(usize, 2), one.items.len);
        try testing.expectEqual(t15, floorSeconds(one.items[0].time));
        try testing.expectEqual(t15 + 60, floorSeconds(one.items[1].time));
        try testing.expectEqual(@as(?f64, 102), one.items[0].open);
        try testing.expectEqual(@as(?f64, 1500), one.items[0].volume);
        try testing.expectEqual(@as(?f64, 100.25), one.items[0].wap);
        try testing.expectEqual(@as(?i32, 12), one.items[0].count);

        const end = test_day_start + 49 * 3600;
        var many = try c.minuteBars(gpa, aapl, .{
            .start = fromSeconds(test_day_start),
            .end = fromSeconds(end),
            .what_to_show = .midpoint,
            .use_rth = false,
        }, .{});
        defer many.deinit();
        try testing.expectEqual(@as(usize, 3), many.items.len);
        try testing.expectEqual(end - 100_000, floorSeconds(many.items[0].time));
        try testing.expectEqual(end - 86400, floorSeconds(many.items[1].time));
        try testing.expectEqual(end - 60, floorSeconds(many.items[2].time));

        var diag: Client.Diagnostics = .{};
        try testing.expectError(error.RequestRejected, c.minuteBars(gpa, aapl, .{ .start = fromSeconds(t15) }, .{ .diagnostics = &diag }));
        try testing.expectEqual(@as(i32, 162), diag.code);

        try testing.expectError(error.Timeout, c.minuteBars(gpa, aapl, .{ .start = fromSeconds(t15) }, .{ .timeout = .fromMilliseconds(100) }));

        // An empty range sends nothing.
        var none = try c.minuteBars(gpa, aapl, .{ .start = fromSeconds(t15), .end = fromSeconds(t15) }, .{});
        defer none.deinit();
        try testing.expectEqual(@as(usize, 0), none.items.len);
    }
    try script.await(io);
}

fn dayText(buf: *[8]u8, d: u64) []const u8 {
    const md = (Day{ .day = @intCast(d) }).calculateYearDay();
    const m = md.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{ md.year, m.month.numeric(), @as(u32, m.day_index) + 1 }) catch unreachable;
}

fn serveDailyBars(server: *FakeServer, today: u64) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);
    var b: [3][8]u8 = undefined;

    // 1. A range in the past.
    {
        var q = try expectBarsRequest(conn, "1 day", 1);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("20250202-00:00:00", q.endDateTime.?);
        try testing.expectEqualStrings("32 D", q.duration.?);
        try testing.expectEqualStrings("BID_ASK", q.whatToShow.?);
        try sendBars(conn, q.reqId, &.{ "20250203", "20250131", "20250102", "20241231" });
    }
    // 2. Up to today: the request ends now.
    {
        var q = try expectBarsRequest(conn, "1 day", 1);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("", q.endDateTime.?);
        try testing.expectEqualStrings("11 D", q.duration.?);
        try sendBars(conn, q.reqId, &.{ dayText(&b[0], today - 11), dayText(&b[1], today - 10), dayText(&b[2], today) });
    }
    // 3. Several years.
    {
        var q = try expectBarsRequest(conn, "1 day", 1);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("", q.endDateTime.?);
        try testing.expectEqualStrings("3 Y", q.duration.?);
        try sendNoData(conn, q.reqId);
    }
    // 4. A bar with a date that is not a day.
    {
        var q = try expectBarsRequest(conn, "1 day", 1);
        defer q.deinit(gpa);
        try sendBars(conn, q.reqId, &.{"1763596800"});
    }
    try conn.expectClose();
}

test "daily bars" {
    const io = testing.io;
    const gpa = testing.allocator;
    const today: u64 = @intCast(@divFloor(floorSeconds(Io.Timestamp.now(io, .real)), std.time.s_per_day));

    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveDailyBars, .{ &server, today });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();
        const aapl = contract.Query.stock("AAPL", "USD");

        var past = try c.dailyBars(gpa, aapl, .{
            .first = try day(2025, 1, 2),
            .last = try day(2025, 1, 31),
            .what_to_show = .bid_ask,
        }, .{});
        defer past.deinit();
        try testing.expectEqual(@as(usize, 2), past.items.len);
        try testing.expectEqual((try day(2025, 1, 2)).day, past.items[0].day.day);
        try testing.expectEqual((try day(2025, 1, 31)).day, past.items[1].day.day);

        var recent = try c.dailyBars(gpa, aapl, .{ .first = .{ .day = @intCast(today - 10) } }, .{});
        defer recent.deinit();
        try testing.expectEqual(@as(usize, 2), recent.items.len);
        try testing.expectEqual(today - 10, recent.items[0].day.day);
        try testing.expectEqual(today, recent.items[1].day.day);

        var years = try c.dailyBars(gpa, aapl, .{ .first = .{ .day = @intCast(today - 800) } }, .{});
        defer years.deinit();
        try testing.expectEqual(@as(usize, 0), years.items.len);

        try testing.expectError(error.UnexpectedResponse, c.dailyBars(gpa, aapl, .{ .first = .{ .day = @intCast(today - 1) } }, .{}));

        // A range in the future sends nothing.
        var future = try c.dailyBars(gpa, aapl, .{ .first = .{ .day = @intCast(today + 5) } }, .{});
        defer future.deinit();
        try testing.expectEqual(@as(usize, 0), future.items.len);
    }
    try script.await(io);
}

fn serveSlowBars(server: *FakeServer, received: *std.Io.Event) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);
    var q = try expectBarsRequest(conn, "1 day", 1);
    defer q.deinit(gpa);
    received.set(testing.io);
    // Never answered; the next message must be its cancel, not a second
    // request (which has to wait for the only slot).
    const cancel = try conn.readRequest();
    try testing.expectEqual(wire.OutMsg.cancel_historical_data, cancel.id);
    try conn.expectClose();
}

fn slowDailyBars(c: *Client) Client.RequestError!void {
    var bars = try c.dailyBars(testing.allocator, contract.Query.stock("AAPL", "USD"), .{ .first = day(2025, 1, 2) catch unreachable }, .{
        .timeout = .fromMilliseconds(400),
    });
    bars.deinit();
}

test "historical requests wait for a free slot" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var received: std.Io.Event = .unset;
    var script = try io.concurrent(serveSlowBars, .{ &server, &received });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port, .max_historical_requests = 1 });
    {
        defer c.close();
        var first = try io.concurrent(slowDailyBars, .{c});
        defer first.cancel(io) catch {};
        try received.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try testing.expectError(error.Timeout, c.dailyBars(gpa, contract.Query.stock("AAPL", "USD"), .{ .first = try day(2025, 1, 2) }, .{
            .timeout = .fromMilliseconds(100),
        }));
        try testing.expectError(error.Timeout, first.await(io));
    }
    try script.await(io);
}
