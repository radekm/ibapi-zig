//! Asynchronous client of TWS / IB Gateway.
//!
//! One `Client` owns one TCP connection. A background reader task (started
//! with `io.concurrent`) decodes incoming messages and routes them to the
//! request they answer. Requests may be issued concurrently from several
//! tasks, e.g. with `io.async(Client.currentTime, .{client})`.
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

const log = std.log.scoped(.ibapi);

/// How many unrouted messages are kept for `nextNotice` before new ones are dropped.
pub const notice_capacity = 256;

io: Io,
gpa: Allocator,
stream: net.Stream,
net_reader: net.Stream.Reader,
net_writer: net.Stream.Writer,
read_buffer: [16 * 1024]u8,
write_buffer: [16 * 1024]u8,
/// Payload of the frame being decoded; used only by the reader.
frame: std.ArrayList(u8),

/// Serialises writers of whole frames.
write_mutex: Io.Mutex,

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
notices: Io.Queue(Incoming),
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
} || Allocator.Error || Io.Cancelable;

/// Errors of `connect`.
pub const ConnectError = error{
    /// The server speaks a protocol version older than `wire.min_server_version`.
    ServerVersionTooOld,
    /// The server closed the connection during the handshake; the reason
    /// (e.g. "client id already in use") is logged.
    ConnectionRejected,
    /// `io` cannot run the reader task concurrently.
    ConcurrencyUnavailable,
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
};

/// Identifies which messages a `Responses` receives.
pub const Key = union(enum) {
    /// Messages whose request id (or `ErrorMessage.id`) equals this value.
    req_id: i32,
    /// Messages of this kind that carry no request id. When several requests
    /// wait for the same kind, they are served in registration order.
    kind: wire.InMsg,
};

/// The stream of messages answering one request. It must stay at a fixed
/// address between `Client.register` and `deinit`.
pub const Responses = struct {
    client: *Client,
    key: Key,
    /// Message id that completes the request; null for subscriptions that
    /// last until `deinit`.
    end: ?wire.InMsg,
    queue: Io.Queue(Incoming),
    /// Set by the reader before it closes `queue` after delivering `end`.
    ended: bool,

    /// Returns the next message, or null after the message that completes the
    /// request has been returned. The caller owns the message and must call
    /// `Incoming.deinit` on it.
    pub fn next(r: *Responses) Error!?Incoming {
        const io = r.client.io;
        return r.queue.getOne(io) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.Closed => {
                if (r.ended) return null;
                r.client.routes_mutex.lockUncancelable(io);
                defer r.client.routes_mutex.unlock(io);
                return r.client.failure orelse error.ConnectionClosed;
            },
        };
    }

    /// Stops receiving messages and frees the ones not yet read. Does not
    /// tell the server anything; cancel server-side subscriptions first.
    pub fn deinit(r: *Responses) void {
        const c = r.client;
        // Closing first wakes the reader if it is blocked on this full queue
        // while holding `routes_mutex`.
        r.queue.close(c.io);
        {
            c.routes_mutex.lockUncancelable(c.io);
            defer c.routes_mutex.unlock(c.io);
            c.removeRouteLocked(r);
        }
        while (r.queue.getOneUncancelable(c.io)) |msg| {
            var m = msg;
            m.deinit(c.gpa);
        } else |_| {}
        r.* = undefined;
    }
};

/// Connects to TWS / IB Gateway, performs the handshake and starts the
/// reader task. Returns once the server has sent the next valid order id.
/// Free with `close`.
pub fn connect(io: Io, gpa: Allocator, options: Options) ConnectError!*Client {
    const c = try gpa.create(Client);
    errdefer gpa.destroy(c);

    const host = try net.HostName.init(options.host);
    const stream = try host.connect(io, options.port, .{ .mode = .stream });
    errdefer stream.close(io);

    c.* = .{
        .io = io,
        .gpa = gpa,
        .stream = stream,
        .net_reader = undefined,
        .net_writer = undefined,
        .read_buffer = undefined,
        .write_buffer = undefined,
        .frame = .empty,
        .write_mutex = .init,
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
    c.net_reader = stream.reader(io, &c.read_buffer);
    c.net_writer = stream.writer(io, &c.write_buffer);
    c.notices = .init(&c.notice_buffer);
    errdefer c.freeState();

    try c.handshake(options);

    c.reader_task = io.concurrent(readLoop, .{c}) catch return error.ConcurrencyUnavailable;
    return c;
}

/// Stops the reader task, closes the connection and frees the client.
/// All `Responses` must be deinitialised before.
pub fn close(c: *Client) void {
    const io = c.io;
    c.reader_task.cancel(io);
    c.stream.close(io);
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

/// Waits for the next message that does not belong to any pending request,
/// e.g. informational errors (codes 2104, 2106, …) or order id updates.
/// Returns null once the connection is closed. The caller owns the message
/// and must call `Incoming.deinit` on it.
pub fn nextNotice(c: *Client) Io.Cancelable!?Incoming {
    return c.notices.getOne(c.io) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.Closed => null,
    };
}

/// Sends a protobuf request. Safe to call from several tasks at once.
pub fn send(c: *Client, id: wire.OutMsg, msg: anytype) Error!void {
    const io = c.io;
    try c.write_mutex.lock(io);
    defer c.write_mutex.unlock(io);
    const w = &c.net_writer.interface;
    wire.writeProtobuf(w, c.gpa, id, msg) catch |err| return c.writeError(err);
    w.flush() catch |err| return c.writeError(err);
}

/// Starts routing messages matching `key` into `r`, which must stay at a
/// fixed address until `r.deinit()`. `buffer` holds messages that were
/// received but not yet read; when it is full the reader waits, so a
/// request must keep reading its responses.
pub fn register(c: *Client, r: *Responses, key: Key, end: ?wire.InMsg, buffer: []Incoming) Error!void {
    const io = c.io;
    r.* = .{ .client = c, .key = key, .end = end, .queue = .init(buffer), .ended = false };
    try c.routes_mutex.lock(io);
    defer c.routes_mutex.unlock(io);
    if (c.failure) |err| return err;
    switch (key) {
        .req_id => |id| try c.by_req_id.putNoClobber(c.gpa, id, r),
        .kind => try c.by_kind.append(c.gpa, r),
    }
}

/// Asks the server for its current time (seconds since the Unix epoch).
pub fn currentTime(c: *Client) (Error || error{UnexpectedResponse})!i64 {
    var buffer: [1]Incoming = undefined;
    var r: Responses = undefined;
    try c.register(&r, .{ .kind = .current_time }, .current_time, &buffer);
    defer r.deinit();
    try c.send(.req_current_time, proto.CurrentTimeRequest{});

    var msg = (try r.next()) orelse return error.UnexpectedResponse;
    defer msg.deinit(c.gpa);
    return msg.current_time.currentTime orelse error.UnexpectedResponse;
}

// ---------------------------------------------------------------------------
// Internals

fn freeState(c: *Client) void {
    // Drain notices nobody read.
    c.notices.close(c.io);
    while (c.notices.getOneUncancelable(c.io)) |msg| {
        var m = msg;
        m.deinit(c.gpa);
    } else |_| {}
    c.frame.deinit(c.gpa);
    c.by_req_id.deinit(c.gpa);
    c.by_kind.deinit(c.gpa);
    c.gpa.free(c.connection_time);
    c.gpa.free(c.accounts);
}

/// Sends the hello and StartApi and reads messages until NextValidId.
fn handshake(c: *Client, options: Options) ConnectError!void {
    const r = &c.net_reader.interface;
    const w = &c.net_writer.interface;

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

    try c.send(.start_api, proto.StartApiRequest{
        .clientId = options.client_id,
        .optionalCapabilities = options.optional_capabilities,
    });

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
        else => log.err("reader stopped: {t}", .{err}),
    }
    c.failAll(if (err == error.Canceled) error.ConnectionClosed else err);
}

fn readUntilFailure(c: *Client) Error {
    const r = &c.net_reader.interface;
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
    route.queue.putOne(io, m) catch |err| {
        m.deinit(c.gpa);
        switch (err) {
            error.Closed => return, // The request gave up; drop the message.
            error.Canceled => return error.Canceled,
        }
    };
    if (route.end == id) {
        route.ended = true;
        c.removeRouteLocked(route);
        route.queue.close(io);
    }
}

fn findRouteLocked(c: *Client, m: Incoming) ?*Responses {
    if (m.requestId()) |id| return c.by_req_id.get(id);
    const id = m.msgId();
    for (c.by_kind.items) |r| {
        if (r.key.kind == id) return r;
    }
    return null;
}

fn removeRouteLocked(c: *Client, r: *Responses) void {
    switch (r.key) {
        .req_id => |id| {
            if (c.by_req_id.get(id) == r) _ = c.by_req_id.remove(id);
        },
        .kind => {
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
    const n = c.notices.put(c.io, (&m)[0..1], 0) catch 0;
    if (n == 0) {
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
    while (it.next()) |r| r.*.queue.close(io);
    for (c.by_kind.items) |r| r.queue.close(io);
    c.by_req_id.clearRetainingCapacity();
    c.by_kind.clearRetainingCapacity();
    c.notices.close(io);
}

fn readError(c: *Client, err: wire.ReadError) Error {
    return switch (err) {
        error.EndOfStream => error.ConnectionClosed,
        error.ReadFailed => if (c.net_reader.err) |e| switch (e) {
            error.Canceled => error.Canceled,
            else => error.ConnectionLost,
        } else error.ConnectionLost,
        error.FrameTooLarge, error.FrameTooShort => error.ProtocolViolation,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeError(c: *Client, err: (wire.WriteError || Allocator.Error)) Error {
    return switch (err) {
        error.WriteFailed => if (c.net_writer.err) |e| switch (e) {
            error.Canceled => error.Canceled,
            else => error.ConnectionLost,
        } else error.ConnectionLost,
        error.FrameTooLarge => error.ProtocolViolation,
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const FakeServer = @import("FakeServer.zig");

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

        var notice = (try c.nextNotice()).?;
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
    var notice = (try c.nextNotice()).?;
    notice.deinit(testing.allocator);
    try testing.expectEqual(@as(?Incoming, null), try c.nextNotice());
}
