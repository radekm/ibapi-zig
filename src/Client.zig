//! Asynchronous client of TWS / IB Gateway.
//!
//! One `Client` owns one TCP connection. A background reader task (started
//! with `io.concurrent`) decodes incoming messages and routes them to the
//! request they answer. Requests may be issued concurrently from several
//! tasks, e.g. with `io.async(Client.currentTime, .{client})`.
//!
//! Every operation is bounded in time: `connect` by `Options.connect_timeout`,
//! each request by `Options.request_timeout`, each write by
//! `Options.write_timeout` and waiting for notices by an explicit timeout.
//!
//! Messages that do not belong to any pending request (informational errors,
//! order id updates, …) are queued as *notices*, see `nextNotice`.
//!
//! The allocator passed to `connect` is used from the reader task and the
//! requesting tasks at the same time, so it must be thread-safe whenever `io`
//! runs tasks in parallel (e.g. `std.Io.Threaded`).

const Client = @This();

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const proto = @import("ibapi_proto");
const wire = @import("wire.zig");
const Incoming = @import("incoming.zig").Incoming;
const Mailbox = @import("mailbox.zig").Mailbox;
const Transport = @import("Transport.zig");
const Pacer = @import("Pacer.zig");
const contract = @import("contract.zig");
const market_data = @import("market_data.zig");
const orders = @import("orders.zig");

const log = std.log.scoped(.ibapi);

/// How many unrouted messages are kept for `nextNotice` before new ones are dropped.
pub const notice_capacity = 256;

io: Io,
gpa: Allocator,
transport: Transport,
read_buffer: [16 * 1024]u8,
write_buffer: [16 * 1024]u8,
/// Payload of the frame being decoded; used only by the reader.
frame: std.ArrayList(u8),

request_timeout: Io.Duration,
snapshot_timeout: Io.Duration,
write_timeout: Io.Duration,

/// Serialises writers of whole frames.
write_mutex: Io.Mutex,
/// Rate limit of outgoing messages; guarded by `write_mutex`.
pacer: Pacer,
/// Held while a request answered by message kind is registered and sent, so
/// that such requests are queued in the order the server receives them.
kind_mutex: Io.Mutex,

server_version: u32,
connection_time: []u8,
accounts: []u8,
next_order_id: std.atomic.Value(i32),
next_req_id: std.atomic.Value(i32),

/// Guards `by_req_id`, `by_kind` and `failure`.
routes_mutex: Io.Mutex,
by_req_id: std.AutoHashMapUnmanaged(i32, *Responses),
/// Requests answered by messages without a request id, in FIFO order.
by_kind: std.ArrayList(*Responses),
/// Why the reader stopped; null while the connection is alive.
failure: ?Error,

notice_buffer: [notice_capacity]Incoming,
notices: Mailbox(Incoming),
dropped_notices: std.atomic.Value(usize),

reader_task: Io.Future(void),

/// Errors of requests on an established connection.
pub const Error = error{
    /// The connection was closed by the server or by `close`.
    ConnectionClosed,
    /// Reading from or writing to the socket failed.
    ConnectionLost,
    /// The server sent a frame that violates the protocol.
    ProtocolViolation,
    /// The operation did not finish in time. A timed-out write leaves a
    /// partial frame on the wire, so the connection is closed in that case.
    Timeout,
    /// `io` cannot run operations concurrently or with a timeout.
    ConcurrencyUnavailable,
} || Allocator.Error || Io.Cancelable;

/// Errors of `connect`.
pub const ConnectError = error{
    /// The server speaks a protocol version older than `wire.min_server_version`.
    ServerVersionTooOld,
    /// The server closed the connection during the handshake; the reason
    /// (e.g. "client id already in use") is logged.
    ConnectionRejected,
} || net.HostName.ConnectError || net.HostName.ValidateError || Error;

/// Connection parameters.
pub const Options = struct {
    /// Host name or IP address of TWS / IB Gateway.
    host: []const u8 = "127.0.0.1",
    /// API port: 7497 paper TWS, 7496 live TWS, 4002 paper Gateway, 4001 live Gateway.
    port: u16 = 7497,
    /// Client id; must be unique among clients connected at the same time.
    client_id: i32 = 0,
    /// Optional capabilities sent with StartApi (usually empty).
    optional_capabilities: []const u8 = "",
    /// Limit for the whole `connect`: TCP connection and handshake up to the
    /// first valid order id. TWS may wait for the user to accept an incoming
    /// connection, so do not set it too low.
    connect_timeout: Io.Duration = .fromSeconds(10),
    /// Default limit for a whole request (sending it and receiving all responses).
    request_timeout: Io.Duration = .fromSeconds(10),
    /// Default limit for `snapshot`. TWS may take up to about 11 seconds to
    /// complete a snapshot, so this is longer than `request_timeout`.
    snapshot_timeout: Io.Duration = .fromSeconds(15),
    /// Limit for sending one message.
    write_timeout: Io.Duration = .fromSeconds(5),
    /// Most messages sent in any one second; further messages wait. TWS
    /// disconnects clients that exceed 50 messages per second. 0 disables
    /// the limit.
    max_messages_per_second: u8 = 50,
    /// Market data requested by `snapshot`. `.frozen` returns live data while
    /// the market is open and the last values when it is closed.
    market_data_type: market_data.MarketDataType = .frozen,
};

/// Identifies which messages a `Responses` receives.
pub const Key = union(enum) {
    /// Messages whose request id (or `ErrorMessage.id`) equals this value.
    req_id: i32,
    /// Messages of these kinds that carry no request id, e.g. open orders
    /// and their status updates. When several requests wait for the same
    /// kind, they are served in registration order. The slice must outlive
    /// the registration (usually it is a compile-time constant).
    kinds: []const wire.InMsg,
};

/// The stream of messages answering one request. It must stay at a fixed
/// address between `Client.register` and `deinit`.
pub const Responses = struct {
    client: *Client,
    key: Key,
    /// Message id that completes the request; null for subscriptions that
    /// last until `deinit`.
    end: ?wire.InMsg,
    box: Mailbox(Incoming),
    /// When `next` gives up.
    deadline: Io.Timeout,
    /// Set by the reader before it closes `box` after delivering `end`.
    ended: bool,

    /// Returns the next message, or null after the message that completes the
    /// request has been returned. Fails with `error.Timeout` when the
    /// deadline given to `Client.register` has passed. The caller owns the
    /// message and must call `Incoming.deinit` on it.
    pub fn next(r: *Responses) Error!?Incoming {
        const c = r.client;
        return r.box.get(c.io, r.deadline) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.Timeout => error.Timeout,
            error.Closed => {
                if (r.ended) return null;
                c.routes_mutex.lockUncancelable(c.io);
                defer c.routes_mutex.unlock(c.io);
                return c.failure orelse error.ConnectionClosed;
            },
        };
    }

    /// Stops receiving messages and frees the ones not yet read. Does not
    /// tell the server anything; cancel server-side subscriptions first.
    pub fn deinit(r: *Responses) void {
        const c = r.client;
        // Closing first wakes the reader if it is blocked on this full mailbox
        // while holding `routes_mutex`.
        r.box.close(c.io);
        {
            c.routes_mutex.lockUncancelable(c.io);
            defer c.routes_mutex.unlock(c.io);
            c.removeRouteLocked(r);
        }
        while (r.box.tryGet(c.io)) |msg| {
            var m = msg;
            m.deinit(c.gpa);
        }
        r.* = undefined;
    }
};

/// Connects to TWS / IB Gateway, performs the handshake and starts the
/// reader task. Returns once the server has sent the next valid order id,
/// or fails with `error.Timeout` after `options.connect_timeout`.
/// Free with `close`.
pub fn connect(io: Io, gpa: Allocator, options: Options) ConnectError!*Client {
    const deadline: Io.Timeout = (Io.Timeout{ .duration = .{
        .raw = options.connect_timeout,
        .clock = .awake,
    } }).toDeadline(io);

    const c = try gpa.create(Client);
    errdefer gpa.destroy(c);

    const host = try net.HostName.init(options.host);
    const stream = try connectWithTimeout(io, host, options.port, deadline);

    c.* = .{
        .io = io,
        .gpa = gpa,
        .transport = undefined,
        .read_buffer = undefined,
        .write_buffer = undefined,
        .frame = .empty,
        .request_timeout = options.request_timeout,
        .snapshot_timeout = options.snapshot_timeout,
        .write_timeout = options.write_timeout,
        .write_mutex = .init,
        .pacer = .init(options.max_messages_per_second),
        .kind_mutex = .init,
        .server_version = 0,
        .connection_time = &.{},
        .accounts = &.{},
        .next_order_id = .init(-1),
        .next_req_id = .init(1),
        .routes_mutex = .init,
        .by_req_id = .empty,
        .by_kind = .empty,
        .failure = null,
        .notice_buffer = undefined,
        .notices = undefined,
        .dropped_notices = .init(0),
        .reader_task = undefined,
    };
    c.transport.init(io, stream, &c.read_buffer, &c.write_buffer);
    errdefer c.transport.close();
    c.notices = .init(&c.notice_buffer);
    errdefer c.freeState();

    c.transport.read_timeout = deadline;
    c.transport.write_timeout = deadline;
    try c.handshake(options);
    // From now on the reader waits for messages indefinitely; requests have
    // their own deadlines.
    c.transport.read_timeout = .none;

    // Applies to all following market data requests of this connection.
    try c.send(.req_market_data_type, proto.MarketDataTypeRequest{
        .marketDataType = @backingInt(options.market_data_type),
    });

    c.reader_task = io.concurrent(readLoop, .{c}) catch return error.ConcurrencyUnavailable;
    return c;
}

/// Stops the reader task, closes the connection and frees the client.
/// All `Responses` must be deinitialised before.
pub fn close(c: *Client) void {
    c.reader_task.cancel(c.io);
    c.transport.close();
    c.freeState();
    c.gpa.destroy(c);
}

/// Protocol version chosen by the server.
pub fn serverVersion(c: *const Client) u32 {
    return c.server_version;
}

/// Connection time as reported by the server.
pub fn connectionTime(c: *const Client) []const u8 {
    return c.connection_time;
}

/// Comma-separated list of accounts managed by this login, as sent during
/// the handshake (may be empty).
pub fn managedAccounts(c: *const Client) []const u8 {
    return c.accounts;
}

/// Next valid order id announced by the server.
pub fn nextOrderId(c: *const Client) i32 {
    return c.next_order_id.load(.monotonic);
}

/// Returns a fresh request id for a new request.
pub fn nextRequestId(c: *Client) i32 {
    return c.next_req_id.fetchAdd(1, .monotonic);
}

/// Number of notices dropped because nobody read them.
pub fn droppedNotices(c: *const Client) usize {
    return c.dropped_notices.load(.monotonic);
}

/// Waits at most `timeout` for the next message that does not belong to any
/// pending request, e.g. informational errors (codes 2104, 2106, …) or
/// order id updates. Returns null once the connection is closed. The caller
/// owns the message and must call `Incoming.deinit` on it.
pub fn nextNotice(c: *Client, timeout: Io.Timeout) (Io.Cancelable || error{Timeout})!?Incoming {
    return c.notices.get(c.io, timeout) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.Timeout => error.Timeout,
        error.Closed => null,
    };
}

/// Sends a protobuf request. Safe to call from several tasks at once.
/// Waits when `Options.max_messages_per_second` would be exceeded. Fails
/// with `error.Timeout` if the message cannot be sent within
/// `Options.write_timeout`; if writing had already started, the connection
/// is closed in that case.
pub fn send(c: *Client, id: wire.OutMsg, msg: anytype) Error!void {
    const io = c.io;
    try c.write_mutex.lock(io);
    defer c.write_mutex.unlock(io);
    var now = Io.Clock.Timestamp.now(io, .awake);
    if (c.pacer.delay(now.raw)) |wait| {
        // Nothing has been written yet, so the connection stays usable.
        if (wait.toNanoseconds() > c.write_timeout.toNanoseconds()) return error.Timeout;
        try io.sleep(wait, .awake);
        now = Io.Clock.Timestamp.now(io, .awake);
    }
    c.pacer.record(now.raw);
    c.transport.write_timeout = (Io.Timeout{ .duration = .{ .raw = c.write_timeout, .clock = .awake } }).toDeadline(io);
    const w = &c.transport.writer;
    wire.writeProtobuf(w, c.gpa, id, msg) catch |err| return c.sendFailed(err);
    w.flush() catch |err| return c.sendFailed(err);
}

/// Starts routing messages matching `key` into `r`, which must stay at a
/// fixed address until `r.deinit()`. `buffer` holds messages that were
/// received but not yet read; when it is full the reader waits, so a
/// request must keep reading its responses. `Responses.next` fails with
/// `error.Timeout` once `timeout` (measured from now) has passed.
pub fn register(c: *Client, r: *Responses, key: Key, end: ?wire.InMsg, buffer: []Incoming, timeout: Io.Timeout) Error!void {
    const io = c.io;
    r.* = .{
        .client = c,
        .key = key,
        .end = end,
        .box = .init(buffer),
        .deadline = timeout.toDeadline(io),
        .ended = false,
    };
    try c.routes_mutex.lock(io);
    defer c.routes_mutex.unlock(io);
    if (c.failure) |err| return err;
    switch (key) {
        .req_id => |id| try c.by_req_id.putNoClobber(c.gpa, id, r),
        .kinds => try c.by_kind.append(c.gpa, r),
    }
}

/// Registers `r` for messages of `kinds` (see `register`) and sends the
/// request `msg`. Concurrent calls are serialised, so the responses, which
/// carry no request id, reach the requests in the order they were sent.
/// After success the caller must call `r.deinit()`; after failure `r` is
/// already deinitialised.
pub fn registerKindsAndSend(
    c: *Client,
    r: *Responses,
    kinds: []const wire.InMsg,
    end: ?wire.InMsg,
    buffer: []Incoming,
    timeout: Io.Timeout,
    id: wire.OutMsg,
    msg: anytype,
) Error!void {
    // Waiting here is bounded by the other sender's write timeout.
    try c.kind_mutex.lock(c.io);
    defer c.kind_mutex.unlock(c.io);
    try c.register(r, .{ .kinds = kinds }, end, buffer, timeout);
    c.send(id, msg) catch |err| {
        r.deinit();
        return err;
    };
}

/// The default deadline of a request starting now (`Options.request_timeout`).
pub fn requestTimeout(c: *const Client) Io.Timeout {
    return .{ .duration = .{ .raw = c.request_timeout, .clock = .awake } };
}

/// Asks the server for its current time (seconds since the Unix epoch).
pub fn currentTime(c: *Client) (Error || error{UnexpectedResponse})!i64 {
    var buffer: [1]Incoming = undefined;
    var r: Responses = undefined;
    try c.registerKindsAndSend(&r, &.{.current_time}, .current_time, &buffer, c.requestTimeout(), .req_current_time, proto.CurrentTimeRequest{});
    defer r.deinit();

    var msg = (try r.next()) orelse return error.UnexpectedResponse;
    defer msg.deinit(c.gpa);
    return msg.current_time.currentTime orelse error.UnexpectedResponse;
}

/// Details of an error that TWS reported for a request.
pub const Diagnostics = struct {
    /// TWS error code, e.g. 200 for "No security definition has been found".
    code: i32 = 0,
    message_buf: [512]u8 = undefined,
    message_len: usize = 0,

    /// The error message sent by TWS (possibly truncated).
    pub fn message(d: *const Diagnostics) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    fn set(d: *Diagnostics, e: proto.ErrorMessage) void {
        const text = e.errorMsg orelse "";
        d.code = e.errorCode orelse 0;
        d.message_len = @min(text.len, d.message_buf.len);
        @memcpy(d.message_buf[0..d.message_len], text[0..d.message_len]);
    }
};

/// Options of a single request.
pub const RequestOptions = struct {
    /// Limit for the whole request; null means `Options.request_timeout`.
    timeout: ?Io.Duration = null,
    /// Receives the TWS error when the request fails with `error.RequestRejected`.
    diagnostics: ?*Diagnostics = null,
};

/// Errors of requests answered by TWS.
pub const RequestError = Error || error{
    /// TWS refused the request; details are in `RequestOptions.diagnostics`.
    RequestRejected,
    /// TWS answered with a message the request does not expect.
    UnexpectedResponse,
};

/// Whether a TWS error code is only a warning that does not end a request:
/// 2100–2199 (connection status, e.g. 2104 "market data farm connection is
/// OK"), 10090 (part of the requested market data is not subscribed) and
/// 10167 (displaying delayed market data).
pub fn isWarningCode(code: i32) bool {
    return (code >= 2100 and code < 2200) or code == 10090 or code == 10167;
}

/// A list of protobuf messages returned by a request, allocated with `gpa`.
pub fn List(comptime T: type) type {
    return struct {
        gpa: Allocator,
        items: []T,

        /// Frees the list and all its messages.
        pub fn deinit(l: *@This()) void {
            for (l.items) |*item| item.deinit(l.gpa);
            l.gpa.free(l.items);
            l.* = undefined;
        }
    };
}

/// Contract details returned by `contractDetails`: one entry per matching
/// contract with fields `contract` and `contractDetails`.
pub const ContractDetailsList = List(proto.ContractData);

/// Option chain parameters returned by `optionChainParams`: one entry per
/// exchange and trading class.
pub const OptionChainList = List(proto.SecDefOptParameter);

/// Looks up all contracts matching `query`, e.g. every exchange listing of a
/// stock or every option of an expiration. The result is allocated with `gpa`
/// and freed with `deinit`. Fails with `error.RequestRejected` when nothing
/// matches (TWS error 200).
///
/// Queries that match thousands of contracts (all options of a symbol) can
/// take long; raise `opts.timeout` for them.
pub fn contractDetails(c: *Client, gpa: Allocator, query: contract.Query, opts: RequestOptions) RequestError!ContractDetailsList {
    const req_id = c.nextRequestId();
    var buffer: [64]Incoming = undefined;
    var r: Responses = undefined;
    try c.register(&r, .{ .req_id = req_id }, .contract_data_end, &buffer, c.timeoutFor(opts));
    defer r.deinit();

    try c.send(.req_contract_data, proto.ContractDataRequest{ .reqId = req_id, .contract = query.toProto() });
    const items = c.collect(gpa, &r, opts.diagnostics, proto.ContractData, &.{ .contract_data, .bond_contract_data }) catch |err| {
        if (err == error.Timeout or err == error.Canceled) c.cancelContractData(req_id);
        return err;
    };
    return .{ .gpa = gpa, .items = items };
}

/// Returns the parameters of the option chain on `underlying`: for each
/// exchange and trading class the multiplier, all expirations and all
/// strikes. The strikes are the union over all expirations; a given
/// expiration need not have every strike. For the actual strikes of one
/// expiration use `contractDetails` with `contract.Query.option(…, expiry, null, right)`.
/// Free the result with `deinit`.
pub fn optionChainParams(c: *Client, gpa: Allocator, underlying: contract.Underlying, opts: RequestOptions) RequestError!OptionChainList {
    const req_id = c.nextRequestId();
    var buffer: [16]Incoming = undefined;
    var r: Responses = undefined;
    try c.register(&r, .{ .req_id = req_id }, .sec_def_opt_parameter_end, &buffer, c.timeoutFor(opts));
    defer r.deinit();

    try c.send(.req_sec_def_opt_params, proto.SecDefOptParamsRequest{
        .reqId = req_id,
        .underlyingSymbol = underlying.symbol,
        .futFopExchange = underlying.fut_fop_exchange,
        .underlyingSecType = underlying.sec_type.code(),
        .underlyingConId = underlying.con_id,
    });
    // TWS has no cancel for this request; a late answer is dropped.
    const items = try c.collect(gpa, &r, opts.diagnostics, proto.SecDefOptParameter, &.{.sec_def_opt_parameter});
    return .{ .gpa = gpa, .items = items };
}

/// Symbols found by `searchSymbols`.
pub const SymbolMatches = struct {
    gpa: Allocator,
    samples: proto.SymbolSamples,

    /// Matching contracts with the derivative types available for each.
    pub fn items(m: *const SymbolMatches) []const proto.ContractDescription {
        return m.samples.contractDescriptions.items;
    }

    /// Frees the matches.
    pub fn deinit(m: *SymbolMatches) void {
        m.samples.deinit(m.gpa);
        m.* = undefined;
    }
};

/// Searches symbols starting with `pattern`, or company names containing it.
/// TWS returns at most a few dozen matches. Free the result with `deinit`.
pub fn searchSymbols(c: *Client, gpa: Allocator, pattern: []const u8, opts: RequestOptions) RequestError!SymbolMatches {
    const req_id = c.nextRequestId();
    var buffer: [1]Incoming = undefined;
    var r: Responses = undefined;
    try c.register(&r, .{ .req_id = req_id }, .symbol_samples, &buffer, c.timeoutFor(opts));
    defer r.deinit();

    try c.send(.req_matching_symbols, proto.MatchingSymbolsRequest{ .reqId = req_id, .pattern = pattern });

    var msg = (try c.nextResponse(&r, opts.diagnostics)) orelse return error.UnexpectedResponse;
    defer msg.deinit(c.gpa);
    if (msg != .symbol_samples) return error.UnexpectedResponse;
    return .{ .gpa = gpa, .samples = try msg.symbol_samples.dupe(gpa) };
}

/// Returns a snapshot of the market data of one contract: bid, ask, last,
/// sizes, daily open/high/low/close and volume; for options also the values
/// of the TWS option model (implied volatility, greeks, underlying price).
///
/// The kind of data follows `Options.market_data_type`. Without a market
/// data subscription for the contract TWS rejects the request (error 354)
/// with `error.RequestRejected`. The default limit is
/// `Options.snapshot_timeout`; on timeout the request is cancelled.
/// Several snapshots may run concurrently (`io.async`), within the TWS
/// limit of simultaneous market data lines (usually 100).
pub fn snapshot(c: *Client, query: contract.Query, opts: RequestOptions) RequestError!market_data.Quote {
    const req_id = c.nextRequestId();
    var buffer: [32]Incoming = undefined;
    var r: Responses = undefined;
    const timeout: Io.Timeout = .{ .duration = .{ .raw = opts.timeout orelse c.snapshot_timeout, .clock = .awake } };
    try c.register(&r, .{ .req_id = req_id }, .tick_snapshot_end, &buffer, timeout);
    defer r.deinit();

    try c.send(.req_mkt_data, proto.MarketDataRequest{
        .reqId = req_id,
        .contract = query.toProto(),
        .snapshot = true,
    });
    return c.collectQuote(&r, opts.diagnostics) catch |err| {
        if (err == error.Timeout or err == error.Canceled) {
            c.send(.cancel_mkt_data, proto.CancelMarketData{ .reqId = req_id }) catch |e| {
                log.debug("cannot cancel market data request {d}: {t}", .{ req_id, e });
            };
        }
        return err;
    };
}

/// Orders returned by `openOrders` and `completedOrders`.
pub const OrderList = List(orders.Order);

/// Returns the open orders of all API clients and the orders entered in
/// TWS (`ReqAllOpenOrders`), each merged with its latest status into one
/// `orders.Order`. Read-only: the request changes nothing in TWS. Free the
/// result with `deinit`.
///
/// `ReqOpenOrders` (orders of this client id only) is deliberately not
/// used: for client id 0 TWS would bind manual TWS orders to the client.
///
/// After this request TWS keeps sending updates of the orders (open order
/// and order status messages); they are delivered as notices
/// (`nextNotice`).
pub fn openOrders(c: *Client, gpa: Allocator, opts: RequestOptions) RequestError!OrderList {
    var buffer: [64]Incoming = undefined;
    var r: Responses = undefined;
    const kinds = &[_]wire.InMsg{ .open_order, .order_status, .open_order_end };
    try c.registerKindsAndSend(&r, kinds, .open_order_end, &buffer, c.timeoutFor(opts), .req_all_open_orders, proto.AllOpenOrdersRequest{});
    defer r.deinit();

    // TWS has no cancel for this request; a late answer goes to the notices.
    var builder: orders.Builder = .init(gpa);
    defer builder.deinit();
    while (try c.nextResponse(&r, opts.diagnostics)) |msg| {
        var m = msg;
        defer m.deinit(c.gpa);
        switch (m) {
            .open_order => |o| try builder.addOrder(try orders.Order.fromOpenOrder(gpa, o)),
            .order_status => |s| try builder.addStatus(s),
            .open_order_end => {},
            else => return error.UnexpectedResponse,
        }
    }
    return .{ .gpa = gpa, .items = try builder.finish() };
}

/// Options of `completedOrders`.
pub const CompletedOrdersOptions = struct {
    /// Only orders placed through the API (not those entered in TWS).
    api_only: bool = false,
    /// Limit for the whole request; null means `Options.request_timeout`.
    timeout: ?Io.Duration = null,
    /// Receives the TWS error when the request fails with `error.RequestRejected`.
    diagnostics: ?*Diagnostics = null,
};

/// Returns the orders completed (filled, cancelled or rejected) today, as
/// far as TWS keeps them. `Order.status` is null; the final status is in
/// `Order.state` (`status`, `completedTime`, `completedStatus`). Free the
/// result with `deinit`.
pub fn completedOrders(c: *Client, gpa: Allocator, opts: CompletedOrdersOptions) RequestError!OrderList {
    var buffer: [64]Incoming = undefined;
    var r: Responses = undefined;
    const kinds = &[_]wire.InMsg{ .completed_order, .completed_orders_end };
    const timeout = c.timeoutFor(.{ .timeout = opts.timeout });
    try c.registerKindsAndSend(&r, kinds, .completed_orders_end, &buffer, timeout, .req_completed_orders, proto.CompletedOrdersRequest{
        .apiOnly = opts.api_only,
    });
    defer r.deinit();

    var items: std.ArrayList(orders.Order) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(gpa);
        items.deinit(gpa);
    }
    while (try c.nextResponse(&r, opts.diagnostics)) |msg| {
        var m = msg;
        defer m.deinit(c.gpa);
        switch (m) {
            .completed_order => |o| {
                try items.ensureUnusedCapacity(gpa, 1);
                items.appendAssumeCapacity(try orders.Order.fromCompletedOrder(gpa, o));
            },
            .completed_orders_end => {},
            else => return error.UnexpectedResponse,
        }
    }
    return .{ .gpa = gpa, .items = try items.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Internals

fn collectQuote(c: *Client, r: *Responses, diagnostics: ?*Diagnostics) RequestError!market_data.Quote {
    var q: market_data.Quote = .{};
    while (try c.nextResponse(r, diagnostics)) |msg| {
        var m = msg;
        defer m.deinit(c.gpa);
        switch (m) {
            .tick_price => |t| market_data.applyPrice(&q, t),
            .tick_size => |t| market_data.applySize(&q, t),
            .tick_string => |t| market_data.applyString(&q, t),
            .tick_option_computation => |t| market_data.applyOptionComputation(&q, t),
            .market_data_type => |t| q.data_type = if (t.marketDataType) |v| @fromBackingInt(@intCast(v)) else null,
            .tick_generic, .tick_req_params, .tick_snapshot_end => {},
            else => return error.UnexpectedResponse,
        }
    }
    return q;
}

fn timeoutFor(c: *const Client, opts: RequestOptions) Io.Timeout {
    return .{ .duration = .{ .raw = opts.timeout orelse c.request_timeout, .clock = .awake } };
}

/// Reads all responses of a request until its end message and returns copies
/// (allocated with `gpa`) of the messages whose tag is in `tags`, all of
/// payload type `T`. Any other message fails with `error.UnexpectedResponse`.
fn collect(
    c: *Client,
    gpa: Allocator,
    r: *Responses,
    diagnostics: ?*Diagnostics,
    comptime T: type,
    comptime tags: []const std.meta.Tag(Incoming),
) RequestError![]T {
    var items: std.ArrayList(T) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(gpa);
        items.deinit(gpa);
    }
    next: while (try c.nextResponse(r, diagnostics)) |msg| {
        var m = msg;
        defer m.deinit(c.gpa);
        inline for (tags) |tag| {
            if (m == tag) {
                try items.ensureUnusedCapacity(gpa, 1);
                items.appendAssumeCapacity(try @field(m, @tagName(tag)).dupe(gpa));
                continue :next;
            }
        }
        if (m.msgId() != r.end) return error.UnexpectedResponse;
    }
    return items.toOwnedSlice(gpa);
}

/// Returns the next response of a request. TWS errors for the request end it
/// with `error.RequestRejected`, except warnings, which are only logged.
fn nextResponse(c: *Client, r: *Responses, diagnostics: ?*Diagnostics) RequestError!?Incoming {
    while (try r.next()) |msg| {
        if (msg != .error_message) return msg;
        var m = msg;
        defer m.deinit(c.gpa);
        const e = m.error_message;
        const code = e.errorCode orelse 0;
        if (isWarningCode(code)) {
            log.info("request {?d}: TWS warning {d}: {s}", .{ e.id, code, e.errorMsg orelse "" });
            continue;
        }
        log.debug("request {?d} rejected by TWS: {d} {s}", .{ e.id, code, e.errorMsg orelse "" });
        if (diagnostics) |d| d.set(e);
        return error.RequestRejected;
    }
    return null;
}

/// Asks TWS to stop sending contract details for an abandoned request.
/// Best effort: older servers cannot cancel and the response is then dropped.
fn cancelContractData(c: *Client, req_id: i32) void {
    if (c.server_version < 215) return;
    c.send(.cancel_contract_data, proto.CancelContractData{ .reqId = req_id }) catch |err| {
        log.debug("cannot cancel contract data request {d}: {t}", .{ req_id, err });
    };
}

fn connectHost(host: net.HostName, io: Io, port: u16) net.HostName.ConnectError!net.Stream {
    return host.connect(io, port, .{ .mode = .stream });
}

/// Opens the TCP connection, giving up at `deadline`. `std.Io.Threaded` does
/// not implement connect timeouts yet, so the connection attempt races a
/// timer and the loser is canceled.
fn connectWithTimeout(io: Io, host: net.HostName, port: u16, deadline: Io.Timeout) ConnectError!net.Stream {
    return raceConnect(io, deadline, connectHost, .{ host, io, port });
}

/// Runs `connectFn(args...)` concurrently with a timer. Returns its stream,
/// or `error.Timeout` if `deadline` comes first; a stream established after
/// that is closed.
fn raceConnect(
    io: Io,
    deadline: Io.Timeout,
    comptime connectFn: anytype,
    args: std.meta.ArgsTuple(@TypeOf(connectFn)),
) ConnectError!net.Stream {
    const Attempt = union(enum) {
        stream: @typeInfo(@TypeOf(connectFn)).@"fn".return_type.?,
        timer: Io.Cancelable!void,
    };
    var buffer: [2]Attempt = undefined;
    var select: Io.Select(Attempt) = .init(io, &buffer);
    defer while (select.cancel()) |late| switch (late) {
        .stream => |result| if (result) |s| s.close(io) else |_| {},
        .timer => {},
    };
    select.concurrent(.stream, connectFn, args) catch return error.ConcurrencyUnavailable;
    select.concurrent(.timer, Io.Timeout.sleep, .{ deadline, io }) catch return error.ConcurrencyUnavailable;
    return switch (try select.await()) {
        .stream => |result| result,
        .timer => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn freeState(c: *Client) void {
    // Drain notices nobody read.
    c.notices.close(c.io);
    while (c.notices.tryGet(c.io)) |msg| {
        var m = msg;
        m.deinit(c.gpa);
    }
    c.frame.deinit(c.gpa);
    c.by_req_id.deinit(c.gpa);
    c.by_kind.deinit(c.gpa);
    c.gpa.free(c.connection_time);
    c.gpa.free(c.accounts);
}

/// Sends the hello and StartApi and reads messages until NextValidId.
fn handshake(c: *Client, options: Options) ConnectError!void {
    const r = &c.transport.reader;
    const w = &c.transport.writer;

    wire.writeHello(w) catch |err| return c.writeError(err);
    w.flush() catch |err| return c.writeError(err);

    const hello_payload = wire.readFrame(r, c.gpa, &c.frame) catch |err| return c.readError(err);
    const hello = wire.parseServerHello(hello_payload) catch return error.ProtocolViolation;
    if (hello.server_version < wire.min_server_version) {
        log.warn("server version {d} is older than the required {d} (TWS / IB Gateway 10.40+)", .{
            hello.server_version, wire.min_server_version,
        });
        return error.ServerVersionTooOld;
    }
    c.server_version = hello.server_version;
    c.connection_time = try c.gpa.dupe(u8, hello.connection_time);

    wire.writeProtobuf(w, c.gpa, .start_api, proto.StartApiRequest{
        .clientId = options.client_id,
        .optionalCapabilities = options.optional_capabilities,
    }) catch |err| return c.writeError(err);
    w.flush() catch |err| return c.writeError(err);

    // The server explains a rejection (e.g. client id in use) with an error
    // message right before it closes the connection.
    var last_error_buf: [256]u8 = undefined;
    var last_error: []const u8 = "no reason given";
    while (true) {
        const msg = wire.readMessage(r, c.gpa, &c.frame) catch |err| switch (err) {
            error.EndOfStream => {
                log.warn("connection rejected: {s}", .{last_error});
                return error.ConnectionRejected;
            },
            else => return c.readError(err),
        };
        var inc = Incoming.decode(c.gpa, msg) catch return error.ProtocolViolation;
        switch (inc) {
            .next_valid_id => |m| {
                c.next_order_id.store(m.orderId orelse -1, .monotonic);
                inc.deinit(c.gpa);
                return;
            },
            .managed_accounts => |m| {
                c.gpa.free(c.accounts);
                c.accounts = &.{};
                c.accounts = try c.gpa.dupe(u8, m.accountsList orelse "");
                inc.deinit(c.gpa);
            },
            .error_message => |m| {
                last_error = std.fmt.bufPrint(&last_error_buf, "error {?d}: {s}", .{
                    m.errorCode, m.errorMsg orelse "",
                }) catch &last_error_buf;
                c.pushNotice(inc);
            },
            else => c.pushNotice(inc),
        }
    }
}

fn readLoop(c: *Client) void {
    const err = c.readUntilFailure();
    switch (err) {
        error.ConnectionClosed => log.info("connection closed by the server", .{}),
        error.Canceled => {},
        else => log.warn("reader stopped: {t}", .{err}),
    }
    c.failAll(if (err == error.Canceled) error.ConnectionClosed else err);
}

fn readUntilFailure(c: *Client) Error {
    const r = &c.transport.reader;
    while (true) {
        const msg = wire.readMessage(r, c.gpa, &c.frame) catch |err| return c.readError(err);
        const inc = Incoming.decode(c.gpa, msg) catch |err| {
            log.warn("cannot decode message {d}: {t}", .{ @backingInt(msg.id), err });
            continue;
        };
        if (inc == .other) {
            log.debug("unhandled message {d} (protobuf: {})", .{ @backingInt(inc.other.id), inc.other.protobuf });
        }
        if (inc == .next_valid_id) {
            if (inc.next_valid_id.orderId) |id| c.next_order_id.store(id, .monotonic);
        }
        c.dispatch(inc) catch |err| return err;
    }
}

/// Delivers a message to the request it belongs to, or to the notices.
fn dispatch(c: *Client, msg: Incoming) Io.Cancelable!void {
    const io = c.io;
    var m = msg;
    c.routes_mutex.lock(io) catch |err| {
        m.deinit(c.gpa);
        return err;
    };
    defer c.routes_mutex.unlock(io);

    const route = c.findRouteLocked(m) orelse {
        c.pushNotice(m);
        return;
    };
    const id = m.msgId();
    // Waits while the request's buffer is full. This is bounded: the request
    // either reads, or times out and closes its mailbox in `deinit`.
    route.box.put(io, m) catch |err| {
        m.deinit(c.gpa);
        switch (err) {
            error.Closed => return, // The request gave up; drop the message.
            error.Canceled => return error.Canceled,
        }
    };
    if (route.end == id) {
        route.ended = true;
        c.removeRouteLocked(route);
        route.box.close(io);
    }
}

fn findRouteLocked(c: *Client, m: Incoming) ?*Responses {
    if (m.requestId()) |id| return c.by_req_id.get(id);
    const id = m.msgId();
    for (c.by_kind.items) |r| {
        if (std.mem.indexOfScalar(wire.InMsg, r.key.kinds, id) != null) return r;
    }
    return null;
}

fn removeRouteLocked(c: *Client, r: *Responses) void {
    switch (r.key) {
        .req_id => |id| {
            if (c.by_req_id.get(id) == r) _ = c.by_req_id.remove(id);
        },
        .kinds => {
            for (c.by_kind.items, 0..) |item, i| {
                if (item == r) {
                    _ = c.by_kind.orderedRemove(i);
                    break;
                }
            }
        },
    }
}

/// Queues a notice without blocking; drops it when the queue is full.
fn pushNotice(c: *Client, msg: Incoming) void {
    var m = msg;
    if (!c.notices.tryPut(c.io, m)) {
        if (c.dropped_notices.fetchAdd(1, .monotonic) == 0) {
            log.warn("notice queue is full, dropping notices (read them with Client.nextNotice)", .{});
        }
        m.deinit(c.gpa);
    }
}

/// Wakes all pending requests with `err` after the reader has stopped.
fn failAll(c: *Client, err: Error) void {
    const io = c.io;
    c.routes_mutex.lockUncancelable(io);
    defer c.routes_mutex.unlock(io);
    c.failure = err;
    var it = c.by_req_id.valueIterator();
    while (it.next()) |r| r.*.box.close(io);
    for (c.by_kind.items) |r| r.box.close(io);
    c.by_req_id.clearRetainingCapacity();
    c.by_kind.clearRetainingCapacity();
    c.notices.close(io);
}

/// Handles a failed send on an established connection. A partially written
/// frame would desynchronise the stream, so the connection is shut down and
/// the reader then fails all pending requests.
fn sendFailed(c: *Client, err: (wire.WriteError || Allocator.Error)) Error {
    const e = c.writeError(err);
    if (e != error.OutOfMemory) {
        c.transport.stream.shutdown(c.io, .both) catch {};
    }
    return e;
}

fn transportError(e: Transport.Error) Error {
    return switch (e) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
        error.SocketFailed => error.ConnectionLost,
    };
}

fn readError(c: *Client, err: wire.ReadError) Error {
    return switch (err) {
        error.EndOfStream => error.ConnectionClosed,
        error.ReadFailed => transportError(c.transport.read_err orelse error.SocketFailed),
        error.FrameTooLarge, error.FrameTooShort => error.ProtocolViolation,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeError(c: *Client, err: (wire.WriteError || Allocator.Error)) Error {
    return switch (err) {
        error.WriteFailed => transportError(c.transport.write_err orelse error.SocketFailed),
        error.FrameTooLarge => error.ProtocolViolation,
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ---------------------------------------------------------------------------
// Tests
const testing = std.testing;
const FakeServer = @import("FakeServer.zig");

fn seconds(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } };
}

fn millis(n: i64) Io.Duration {
    return .fromMilliseconds(n);
}

fn serveCurrentTime(server: *FakeServer, requests: usize) !void {
    const conn = try server.accept(testing.io, testing.allocator);
    defer conn.deinit();
    try conn.handshake(3);
    for (0..requests) |i| {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_current_time, req.id);
        try conn.send(.current_time, proto.CurrentTime{ .currentTime = 1_763_478_840 + @as(i64, @intCast(i)) });
    }
    try conn.expectClose();
}

test "connect performs the handshake and answers requests" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveCurrentTime, .{ &server, 1 });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port, .client_id = 3 });
    {
        defer c.close();
        try testing.expectEqual(wire.max_client_version, c.serverVersion());
        try testing.expectEqualStrings("20261118 16:54:00 Europe/Prague", c.connectionTime());
        try testing.expectEqualStrings("DU0000001", c.managedAccounts());
        try testing.expectEqual(@as(i32, 1), c.nextOrderId());

        try testing.expectEqual(@as(i64, 1_763_478_840), try c.currentTime());

        var notice = (try c.nextNotice(seconds(5))).?;
        defer notice.deinit(testing.allocator);
        try testing.expectEqual(@as(?i32, 2104), notice.error_message.errorCode);
    }
    try script.await(io);
}

fn currentTimeTask(c: *Client) !i64 {
    return c.currentTime();
}

test "concurrent requests of the same kind are answered in order" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveCurrentTime, .{ &server, 2 });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port, .client_id = 3 });
    {
        defer c.close();
        var a = try io.concurrent(currentTimeTask, .{c});
        defer _ = a.cancel(io) catch {};
        var b = try io.concurrent(currentTimeTask, .{c});
        defer _ = b.cancel(io) catch {};
        const ta = try a.await(io);
        const tb = try b.await(io);
        // Each request got exactly one of the two answers.
        try testing.expectEqual(@as(i64, 2 * 1_763_478_840 + 1), ta + tb);
    }
    try script.await(io);
}

fn serveOldVersion(server: *FakeServer) !void {
    const conn = try server.accept(testing.io, testing.allocator);
    defer conn.deinit();
    try conn.expectHello();
    try conn.sendHello(wire.min_server_version - 1);
    try conn.expectClose();
}

test "servers older than the minimum version are rejected" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveOldVersion, .{&server});
    defer script.cancel(io) catch {};

    try testing.expectError(error.ServerVersionTooOld, Client.connect(io, testing.allocator, .{ .port = server.port }));
    try script.await(io);
}

fn serveRejection(server: *FakeServer) !void {
    const conn = try server.accept(testing.io, testing.allocator);
    defer conn.deinit();
    try conn.expectHello();
    try conn.sendHello(wire.max_client_version);
    _ = try conn.readRequest();
    try conn.send(.error_message, proto.ErrorMessage{
        .id = -1,
        .errorCode = 326,
        .errorMsg = "Unable to connect as the client id is already in use.",
    });
}

test "a connection closed during the handshake is reported as rejected" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveRejection, .{&server});
    defer script.cancel(io) catch {};

    try testing.expectError(error.ConnectionRejected, Client.connect(io, testing.allocator, .{ .port = server.port }));
    try script.await(io);
}

fn serveThenHangUp(server: *FakeServer) !void {
    const conn = try server.accept(testing.io, testing.allocator);
    defer conn.deinit();
    try conn.handshake(0);
    const req = try conn.readRequest();
    try testing.expectEqual(wire.OutMsg.req_current_time, req.id);
    // Close without answering.
}

test "pending requests fail when the server closes the connection" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveThenHangUp, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port });
    defer c.close();
    try testing.expectError(error.ConnectionClosed, c.currentTime());
    try script.await(io);
    // Notices end once the connection is gone.
    var notice = (try c.nextNotice(seconds(5))).?;
    notice.deinit(testing.allocator);
    try testing.expectEqual(@as(?Incoming, null), try c.nextNotice(seconds(5)));
}

fn serveSilently(server: *FakeServer, after_handshake: bool) !void {
    const conn = try server.accept(testing.io, testing.allocator);
    defer conn.deinit();
    if (!after_handshake) {
        try conn.expectHello(); // ...and never answer it.
    } else {
        try conn.handshake(0);
        // Read the request but never answer it.
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_current_time, req.id);
        // Answer only the second request.
        const req2 = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_current_time, req2.id);
        try conn.send(.current_time, proto.CurrentTime{ .currentTime = 42 });
    }
    try conn.expectClose();
}

test "connect times out when the server does not answer the hello" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveSilently, .{ &server, false });
    defer script.cancel(io) catch {};

    try testing.expectError(error.Timeout, Client.connect(io, testing.allocator, .{
        .port = server.port,
        .connect_timeout = millis(100),
    }));
    try script.await(io);
}

test "a request without an answer times out and the connection stays usable" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveSilently, .{ &server, true });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{
        .port = server.port,
        .request_timeout = millis(100),
    });
    {
        defer c.close();
        try testing.expectError(error.Timeout, c.currentTime());
        try testing.expectEqual(@as(i64, 42), try c.currentTime());
    }
    try script.await(io);
}

test "waiting for notices times out" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveCurrentTime, .{ &server, 0 });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port, .client_id = 3 });
    {
        defer c.close();
        var notice = (try c.nextNotice(seconds(5))).?; // 2104 from the handshake
        notice.deinit(testing.allocator);
        try testing.expectError(error.Timeout, c.nextNotice(.{ .duration = .{ .raw = millis(50), .clock = .awake } }));
    }
    try script.await(io);
}

fn hangingConnect(io: Io) net.HostName.ConnectError!net.Stream {
    try io.sleep(.fromSeconds(60), .awake);
    return error.ConnectionRefused;
}

test "a TCP connect that hangs is abandoned at the deadline" {
    const io = testing.io;
    const start = Io.Clock.Timestamp.now(io, .awake);
    const deadline = (Io.Timeout{ .duration = .{ .raw = millis(100), .clock = .awake } }).toDeadline(io);
    try testing.expectError(error.Timeout, raceConnect(io, deadline, hangingConnect, .{io}));
    const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake));
    try testing.expect(elapsed.raw.toMilliseconds() < 5000);
}

fn serveContracts(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);

    // 1. A stock query with two matches and a warning in between.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_contract_data, req.id);
        var q = try req.decode(proto.ContractDataRequest, gpa);
        defer q.deinit(gpa);
        const qc = q.contract.?;
        try testing.expectEqualStrings("AAPL", qc.symbol.?);
        try testing.expectEqualStrings("STK", qc.secType.?);
        try testing.expectEqualStrings("SMART", qc.exchange.?);
        try testing.expectEqualStrings("USD", qc.currency.?);
        try testing.expectEqual(@as(?i32, null), qc.conId);

        try conn.send(.contract_data, proto.ContractData{
            .reqId = q.reqId,
            .contract = .{ .conId = 265598, .symbol = "AAPL", .secType = "STK", .exchange = "SMART", .primaryExch = "NASDAQ", .currency = "USD" },
            .contractDetails = .{ .longName = "APPLE INC", .minTick = "0.01" },
        });
        try conn.send(.error_message, proto.ErrorMessage{ .id = q.reqId, .errorCode = 2158, .errorMsg = "Sec-def data farm connection is OK" });
        try conn.send(.contract_data, proto.ContractData{
            .reqId = q.reqId,
            .contract = .{ .conId = 38708077, .symbol = "AAPL", .secType = "STK", .exchange = "MEXI", .currency = "MXN" },
            .contractDetails = .{ .longName = "APPLE INC" },
        });
        try conn.send(.contract_data_end, proto.ContractDataEnd{ .reqId = q.reqId });
    }
    // 2. Nothing found.
    {
        const req = try conn.readRequest();
        var q = try req.decode(proto.ContractDataRequest, gpa);
        defer q.deinit(gpa);
        try conn.send(.error_message, proto.ErrorMessage{
            .id = q.reqId,
            .errorCode = 200,
            .errorMsg = "No security definition has been found for the request",
        });
    }
    // 3. No answer: the client times out and cancels the request.
    {
        const req = try conn.readRequest();
        var q = try req.decode(proto.ContractDataRequest, gpa);
        defer q.deinit(gpa);
        const cancel = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.cancel_contract_data, cancel.id);
        var cq = try cancel.decode(proto.CancelContractData, gpa);
        defer cq.deinit(gpa);
        try testing.expectEqual(q.reqId, cq.reqId);
    }
    // 4. Symbol search.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_matching_symbols, req.id);
        var q = try req.decode(proto.MatchingSymbolsRequest, gpa);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("APP", q.pattern.?);

        var samples: proto.SymbolSamples = .{ .reqId = q.reqId };
        defer samples.contractDescriptions.deinit(gpa);
        try samples.contractDescriptions.append(gpa, .{
            .contract = .{ .conId = 265598, .symbol = "AAPL", .secType = "STK", .primaryExch = "NASDAQ", .currency = "USD" },
        });
        try samples.contractDescriptions.append(gpa, .{
            .contract = .{ .conId = 543210, .symbol = "APP", .secType = "STK", .primaryExch = "NASDAQ", .currency = "USD" },
        });
        try conn.send(.symbol_samples, samples);
    }
    try conn.expectClose();
}

test "contract details, rejections, timeouts and symbol search" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveContracts, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();

        var list = try c.contractDetails(gpa, contract.Query.stock("AAPL", "USD"), .{});
        defer list.deinit();
        try testing.expectEqual(@as(usize, 2), list.items.len);
        try testing.expectEqual(@as(?i32, 265598), list.items[0].contract.?.conId);
        try testing.expectEqualStrings("NASDAQ", list.items[0].contract.?.primaryExch.?);
        try testing.expectEqualStrings("APPLE INC", list.items[0].contractDetails.?.longName.?);
        try testing.expectEqualStrings("MXN", list.items[1].contract.?.currency.?);

        var diag: Diagnostics = .{};
        try testing.expectError(error.RequestRejected, c.contractDetails(gpa, contract.Query.stock("NOPE", "USD"), .{ .diagnostics = &diag }));
        try testing.expectEqual(@as(i32, 200), diag.code);
        try testing.expectEqualStrings("No security definition has been found for the request", diag.message());

        try testing.expectError(error.Timeout, c.contractDetails(gpa, contract.Query.option("AAPL", "USD", null, null, null), .{
            .timeout = millis(100),
        }));

        var matches = try c.searchSymbols(gpa, "APP", .{});
        defer matches.deinit();
        try testing.expectEqual(@as(usize, 2), matches.items().len);
        try testing.expectEqualStrings("APP", matches.items()[1].contract.?.symbol.?);
    }
    try script.await(io);
}

fn serveOptionChain(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);

    const req = try conn.readRequest();
    try testing.expectEqual(wire.OutMsg.req_sec_def_opt_params, req.id);
    var q = try req.decode(proto.SecDefOptParamsRequest, gpa);
    defer q.deinit(gpa);
    try testing.expectEqualStrings("AAPL", q.underlyingSymbol.?);
    try testing.expectEqualStrings("STK", q.underlyingSecType.?);
    try testing.expectEqual(@as(?i32, 265598), q.underlyingConId);
    try testing.expectEqual(@as(?[]const u8, null), q.futFopExchange);

    for ([_][]const u8{ "SMART", "CBOE" }) |exchange| {
        var p: proto.SecDefOptParameter = .{
            .reqId = q.reqId,
            .exchange = exchange,
            .underlyingConId = 265598,
            .tradingClass = "AAPL",
            .multiplier = "100",
        };
        defer p.expirations.deinit(gpa);
        defer p.strikes.deinit(gpa);
        try p.expirations.appendSlice(gpa, &.{ "20261120", "20261127", "20261218" });
        try p.strikes.appendSlice(gpa, &.{ 180, 185, 190, 195, 200 });
        try conn.send(.sec_def_opt_parameter, p);
    }
    try conn.send(.sec_def_opt_parameter_end, proto.SecDefOptParameterEnd{ .reqId = q.reqId });
    try conn.expectClose();
}

test "option chain parameters are collected per exchange" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveOptionChain, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();
        var chain = try c.optionChainParams(gpa, .{ .symbol = "AAPL", .con_id = 265598 }, .{});
        defer chain.deinit();
        try testing.expectEqual(@as(usize, 2), chain.items.len);
        const smart = chain.items[0];
        try testing.expectEqualStrings("SMART", smart.exchange.?);
        try testing.expectEqualStrings("100", smart.multiplier.?);
        try testing.expectEqualStrings("20261218", smart.expirations.items[2]);
        try testing.expectEqual(@as(f64, 200), smart.strikes.items[4]);
        try testing.expectEqualStrings("CBOE", chain.items[1].exchange.?);
    }
    try script.await(io);
}

fn serveSnapshots(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);
    try testing.expectEqual(@as(i32, 2), conn.market_data_type); // frozen by default

    // 1. Stock.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_mkt_data, req.id);
        var q = try req.decode(proto.MarketDataRequest, gpa);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(?bool, true), q.snapshot);
        try testing.expectEqual(@as(?i32, 265598), q.contract.?.conId);
        try testing.expectEqualStrings("SMART", q.contract.?.exchange.?);
        const id = q.reqId;
        try conn.send(.market_data_type, proto.MarketDataType{ .reqId = id, .marketDataType = 2 });
        try conn.send(.tick_req_params, proto.TickReqParams{ .reqId = id, .minTick = "0.01" });
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 1, .price = 189.5, .size = "300" });
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 2, .price = 189.6, .size = "200" });
        try conn.send(.error_message, proto.ErrorMessage{ .id = id, .errorCode = 10090, .errorMsg = "Part of requested market data is not subscribed." });
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 4, .price = 189.55, .size = "100" });
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 9, .price = 188.1 });
        try conn.send(.tick_size, proto.TickSize{ .reqId = id, .tickType = 8, .size = "1234567" });
        try conn.send(.tick_string, proto.TickString{ .reqId = id, .tickType = 45, .value = "1763478840" });
        try conn.send(.tick_snapshot_end, proto.TickSnapshotEnd{ .reqId = id });
    }
    // 2. Option with model values.
    {
        const req = try conn.readRequest();
        var q = try req.decode(proto.MarketDataRequest, gpa);
        defer q.deinit(gpa);
        try testing.expectEqualStrings("OPT", q.contract.?.secType.?);
        const id = q.reqId;
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 1, .price = 7.8, .size = "12" });
        try conn.send(.tick_price, proto.TickPrice{ .reqId = id, .tickType = 2, .price = 7.95, .size = "8" });
        try conn.send(.tick_option_computation, proto.TickOptionComputation{
            .reqId = id,
            .tickType = 10,
            .impliedVol = 0.248,
            .delta = 0.51,
            .optPrice = 7.8,
            .pvDividend = 0.24,
            .gamma = 0.021,
            .vega = 0.31,
            .theta = -0.045,
            .undPrice = 189.55,
        });
        try conn.send(.tick_option_computation, proto.TickOptionComputation{
            .reqId = id,
            .tickType = 13,
            .impliedVol = 0.25,
            .delta = 0.52,
            .optPrice = 7.87,
            .pvDividend = 0.24,
            .gamma = 0.021,
            .vega = 0.31,
            .theta = -0.046,
            .undPrice = 189.55,
        });
        try conn.send(.tick_snapshot_end, proto.TickSnapshotEnd{ .reqId = id });
    }
    // 3. No subscription.
    {
        const req = try conn.readRequest();
        var q = try req.decode(proto.MarketDataRequest, gpa);
        defer q.deinit(gpa);
        try conn.send(.error_message, proto.ErrorMessage{ .id = q.reqId, .errorCode = 354, .errorMsg = "Requested market data is not subscribed." });
    }
    // 4. No answer: the client times out and cancels.
    {
        const req = try conn.readRequest();
        var q = try req.decode(proto.MarketDataRequest, gpa);
        defer q.deinit(gpa);
        const cancel = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.cancel_mkt_data, cancel.id);
        var cq = try cancel.decode(proto.CancelMarketData, gpa);
        defer cq.deinit(gpa);
        try testing.expectEqual(q.reqId, cq.reqId);
    }
    try conn.expectClose();
}

test "snapshots of stocks and options, rejections and timeouts" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveSnapshots, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();

        const stock = try c.snapshot(contract.Query.byConId(265598, "SMART"), .{});
        try testing.expectEqual(@as(?market_data.MarketDataType, .frozen), stock.data_type);
        try testing.expectEqual(@as(?f64, 189.5), stock.bid);
        try testing.expectEqual(@as(?f64, 200), stock.ask_size);
        try testing.expectEqual(@as(?f64, 189.55), stock.last);
        try testing.expectEqual(@as(?f64, 188.1), stock.close);
        try testing.expectEqual(@as(?f64, 1234567), stock.volume);
        try testing.expectEqual(@as(?i64, 1763478840), stock.last_timestamp);
        try testing.expectEqual(@as(?market_data.OptionComputation, null), stock.model_computation);

        const option = try c.snapshot(contract.Query.option("AAPL", "USD", "20261218", 190, .call), .{});
        try testing.expectEqual(@as(?f64, 7.95), option.ask);
        try testing.expectEqual(@as(?f64, 0.248), option.bid_computation.?.implied_vol);
        const model = option.model_computation.?;
        try testing.expectEqual(@as(?f64, 0.52), model.delta);
        try testing.expectEqual(@as(?f64, -0.046), model.theta);
        try testing.expectEqual(@as(?f64, 189.55), model.underlying_price);

        var diag: Diagnostics = .{};
        try testing.expectError(error.RequestRejected, c.snapshot(contract.Query.byConId(1, "SMART"), .{ .diagnostics = &diag }));
        try testing.expectEqual(@as(i32, 354), diag.code);

        try testing.expectError(error.Timeout, c.snapshot(contract.Query.byConId(2, "SMART"), .{ .timeout = millis(100) }));
    }
    try script.await(io);
}

fn serveOrders(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);

    // 1. All open orders: an API order and two orders entered in TWS.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_all_open_orders, req.id);
        try conn.send(.open_order, proto.OpenOrder{
            .orderId = 5,
            .contract = .{ .conId = 265598, .symbol = "AAPL", .secType = "STK", .exchange = "SMART", .currency = "USD" },
            .order = .{ .orderId = 5, .clientId = 3, .permId = 1001, .action = "BUY", .totalQuantity = "100", .orderType = "LMT", .lmtPrice = 180, .tif = "DAY", .account = "DU0000001" },
            .orderState = .{ .status = "Submitted" },
        });
        try conn.send(.order_status, proto.OrderStatus{ .orderId = 5, .clientId = 3, .permId = 1001, .status = "Submitted", .filled = "40", .remaining = "60", .avgFillPrice = 179.9 });
        // Not related to the request: goes to the notices.
        try conn.send(.error_message, proto.ErrorMessage{ .id = -1, .errorCode = 2106, .errorMsg = "HMDS data farm connection is OK" });
        try conn.send(.open_order, proto.OpenOrder{
            .orderId = 0,
            .contract = .{ .conId = 272093, .symbol = "MSFT", .secType = "STK" },
            .order = .{ .clientId = 0, .permId = 2002, .action = "SELL", .totalQuantity = "10", .orderType = "STP", .auxPrice = 300, .tif = "GTC" },
            .orderState = .{ .status = "PreSubmitted" },
        });
        try conn.send(.open_order, proto.OpenOrder{
            .orderId = 0,
            .contract = .{ .conId = 76792991, .symbol = "TSLA", .secType = "STK" },
            .order = .{ .clientId = 0, .permId = 2003, .action = "BUY", .totalQuantity = "1", .orderType = "MKT" },
            .orderState = .{ .status = "PreSubmitted" },
        });
        try conn.send(.order_status, proto.OrderStatus{ .orderId = 0, .permId = 2002, .status = "PreSubmitted", .filled = "0", .remaining = "10" });
        try conn.send(.open_order_end, proto.OpenOrdersEnd{});
    }
    // 2. No open orders.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_all_open_orders, req.id);
        try conn.send(.open_order_end, proto.OpenOrdersEnd{});
    }
    // 3. Completed orders.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_completed_orders, req.id);
        var q = try req.decode(proto.CompletedOrdersRequest, gpa);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(?bool, true), q.apiOnly);
        try conn.send(.completed_order, proto.CompletedOrder{
            .contract = .{ .symbol = "AAPL" },
            .order = .{ .permId = 999, .action = "SELL", .totalQuantity = "50", .filledQuantity = "50" },
            .orderState = .{ .status = "Filled", .completedTime = "20261118 15:30:00 Europe/Prague", .completedStatus = "Filled Size: 50" },
        });
        try conn.send(.completed_order, proto.CompletedOrder{
            .contract = .{ .symbol = "AAPL" },
            .order = .{ .permId = 1000, .action = "BUY", .totalQuantity = "50", .filledQuantity = "0" },
            .orderState = .{ .status = "Cancelled", .completedStatus = "Cancelled by Trader" },
        });
        try conn.send(.completed_orders_end, proto.CompletedOrdersEnd{});
    }
    // 4. No answer: the request times out.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_all_open_orders, req.id);
    }
    // 5. The next request shows that the client gave up request 4, so this
    // update belongs to no request.
    {
        const req = try conn.readRequest();
        try testing.expectEqual(wire.OutMsg.req_current_time, req.id);
        try conn.send(.order_status, proto.OrderStatus{ .orderId = 5, .clientId = 3, .permId = 1001, .status = "Filled", .filled = "100", .remaining = "0" });
        try conn.send(.current_time, proto.CurrentTime{ .currentTime = 42 });
    }
    try conn.expectClose();
}

test "open and completed orders" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveOrders, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, gpa, .{ .port = server.port });
    {
        defer c.close();

        var all = try c.openOrders(gpa, .{});
        defer all.deinit();
        try testing.expectEqual(@as(usize, 3), all.items.len);

        const aapl = &all.items[0];
        try testing.expectEqual(@as(i32, 5), aapl.order_id);
        try testing.expectEqualStrings("AAPL", aapl.contract.symbol.?);
        try testing.expectEqual(orders.Status.submitted, aapl.statusKind());
        try testing.expectEqual(@as(?orders.Action, .buy), aapl.action());
        try testing.expectEqual(@as(?f64, 40), aapl.filledQuantity());
        try testing.expectEqual(@as(?f64, 60), aapl.remainingQuantity());
        try testing.expectEqual(@as(?f64, 179.9), aapl.avgFillPrice());
        try testing.expectEqualStrings("DU0000001", aapl.account().?);

        const msft = &all.items[1];
        try testing.expectEqual(@as(?i64, 2002), msft.permId());
        try testing.expectEqual(@as(?f64, 300), msft.auxPrice());
        try testing.expectEqual(@as(?f64, 10), msft.remainingQuantity());

        const tsla = &all.items[2];
        try testing.expectEqual(@as(?proto.OrderStatus, null), tsla.status);
        try testing.expectEqual(orders.Status.pre_submitted, tsla.statusKind());

        var none = try c.openOrders(gpa, .{});
        defer none.deinit();
        try testing.expectEqual(@as(usize, 0), none.items.len);

        var done = try c.completedOrders(gpa, .{ .api_only = true });
        defer done.deinit();
        try testing.expectEqual(@as(usize, 2), done.items.len);
        try testing.expectEqual(orders.Status.filled, done.items[0].statusKind());
        try testing.expectEqualStrings("Filled Size: 50", done.items[0].state.completedStatus.?);
        try testing.expectEqual(orders.Status.cancelled, done.items[1].statusKind());

        try testing.expectError(error.Timeout, c.openOrders(gpa, .{ .timeout = millis(100) }));
        try testing.expectEqual(@as(i64, 42), try c.currentTime());

        // Notices: 2104 from the handshake, 2106 from the middle of the
        // first request, then the unsolicited status update.
        var n1 = (try c.nextNotice(seconds(5))).?;
        defer n1.deinit(gpa);
        try testing.expectEqual(@as(?i32, 2104), n1.error_message.errorCode);
        var n2 = (try c.nextNotice(seconds(5))).?;
        defer n2.deinit(gpa);
        try testing.expectEqual(@as(?i32, 2106), n2.error_message.errorCode);
        var n3 = (try c.nextNotice(seconds(5))).?;
        defer n3.deinit(gpa);
        try testing.expectEqualStrings("Filled", n3.order_status.status.?);
    }
    try script.await(io);
}

fn serveOrdersAndTime(server: *FakeServer) !void {
    const gpa = testing.allocator;
    const conn = try server.accept(testing.io, gpa);
    defer conn.deinit();
    try conn.handshake(0);

    // Both requests arrive in either order; the answers are interleaved.
    var seen: [2]wire.OutMsg = undefined;
    for (&seen) |*s| s.* = (try conn.readRequest()).id;
    try testing.expect(std.mem.indexOfScalar(wire.OutMsg, &seen, .req_current_time) != null);
    try testing.expect(std.mem.indexOfScalar(wire.OutMsg, &seen, .req_all_open_orders) != null);

    try conn.send(.open_order, proto.OpenOrder{ .orderId = 1, .order = .{ .clientId = 0, .permId = 7, .action = "BUY", .totalQuantity = "1" } });
    try conn.send(.current_time, proto.CurrentTime{ .currentTime = 42 });
    try conn.send(.order_status, proto.OrderStatus{ .orderId = 1, .clientId = 0, .permId = 7, .status = "Submitted" });
    try conn.send(.open_order_end, proto.OpenOrdersEnd{});
    try conn.expectClose();
}

fn openOrdersTask(c: *Client) !usize {
    var list = try c.openOrders(testing.allocator, .{});
    defer list.deinit();
    try testing.expectEqual(orders.Status.submitted, list.items[0].statusKind());
    return list.items.len;
}

test "open orders and another request run concurrently" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveOrdersAndTime, .{&server});
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port });
    {
        defer c.close();
        var a = try io.concurrent(openOrdersTask, .{c});
        defer _ = a.cancel(io) catch {};
        var b = try io.concurrent(currentTimeTask, .{c});
        defer _ = b.cancel(io) catch {};
        try testing.expectEqual(@as(usize, 1), try a.await(io));
        try testing.expectEqual(@as(i64, 42), try b.await(io));
    }
    try script.await(io);
}

test "outgoing messages are paced" {
    const io = testing.io;
    var server = try FakeServer.listen(io);
    defer server.deinit(io);
    var script = try io.concurrent(serveCurrentTime, .{ &server, 6 });
    defer script.cancel(io) catch {};

    const c = try Client.connect(io, testing.allocator, .{ .port = server.port, .client_id = 3, .max_messages_per_second = 5 });
    {
        defer c.close();
        // With the market data type sent by `connect` these are 7 messages,
        // so the last two must wait for the one-second window to move.
        const start = Io.Clock.Timestamp.now(io, .awake);
        for (0..6) |_| _ = try c.currentTime();
        const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake));
        try testing.expect(elapsed.raw.toMilliseconds() >= 900);
    }
    try script.await(io);
}
