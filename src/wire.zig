//! Framing and handshake of the TWS API.
//!
//! This layer knows how bytes are put on the wire but nothing about the
//! meaning of individual messages. See `docs/en/protocol.md`.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// Oldest server version the library works with: from this version on, every
/// request used by the library is encoded as protobuf.
pub const min_server_version: u32 = 213;

/// Newest protocol version the library offers during the handshake.
pub const max_client_version: u32 = 226;

/// Oldest protocol version offered during the handshake. Older servers are
/// rejected after the handshake with a clear error instead of a refused connection.
pub const min_client_version: u32 = 100;

/// Message ids above this offset carry a protobuf body.
pub const protobuf_id_offset: u32 = 200;

/// Largest frame payload the protocol allows.
pub const max_frame_len: u32 = 0xFFFFFF;

/// Ids of messages sent by the server. Non-exhaustive: ids the library does
/// not know are still delivered as `@enumFromInt`.
pub const InMsg = enum(u32) {
    tick_price = 1,
    tick_size = 2,
    order_status = 3,
    error_message = 4,
    open_order = 5,
    next_valid_id = 9,
    contract_data = 10,
    managed_accounts = 15,
    tick_option_computation = 21,
    tick_generic = 45,
    tick_string = 46,
    current_time = 49,
    contract_data_end = 52,
    open_order_end = 53,
    tick_snapshot_end = 57,
    market_data_type = 58,
    sec_def_opt_parameter = 75,
    sec_def_opt_parameter_end = 76,
    symbol_samples = 79,
    tick_req_params = 81,
    completed_order = 101,
    completed_orders_end = 102,
    current_time_in_millis = 109,
    _,
};

/// Ids of messages sent by the client. Only read-only requests are listed;
/// order-changing requests are deliberately absent (see AGENTS.md).
pub const OutMsg = enum(u32) {
    req_mkt_data = 1,
    cancel_mkt_data = 2,
    req_open_orders = 5,
    req_ids = 8,
    req_contract_data = 9,
    req_all_open_orders = 16,
    req_managed_accts = 17,
    req_current_time = 49,
    req_market_data_type = 59,
    start_api = 71,
    req_sec_def_opt_params = 78,
    req_matching_symbols = 81,
    req_completed_orders = 99,
    req_current_time_in_millis = 105,
    cancel_contract_data = 106,
};

/// A decoded frame header with a borrowed body.
pub const Message = struct {
    /// Message id with the protobuf offset removed.
    id: InMsg,
    /// True if `body` is protobuf, false for the legacy text format.
    protobuf: bool,
    /// Message body; borrowed from the buffer passed to `readMessage`.
    body: []const u8,
};

/// The server's reply to the client's hello.
pub const ServerHello = struct {
    /// Protocol version chosen by the server.
    server_version: u32,
    /// Connection time as formatted by the server, borrowed from the frame.
    connection_time: []const u8,
};

/// Errors of reading frames.
pub const ReadError = Reader.Error || Allocator.Error || error{
    /// The length prefix exceeds `max_frame_len`.
    FrameTooLarge,
    /// The frame is too short to contain a message id.
    FrameTooShort,
};

/// Errors of writing frames.
pub const WriteError = Writer.Error || error{FrameTooLarge};

/// Sends the hello that starts every connection: the `API\0` prefix and
/// the offered range of protocol versions. Does not flush.
pub fn writeHello(w: *Writer) WriteError!void {
    var buf: [32]u8 = undefined;
    const versions = std.fmt.bufPrint(&buf, "v{d}..{d}", .{ min_client_version, max_client_version }) catch unreachable;
    try w.writeAll("API\x00");
    try w.writeInt(u32, @intCast(versions.len), .big);
    try w.writeAll(versions);
}

/// Parses the payload of the first frame sent by the server: two
/// NUL-terminated fields, the server version and the connection time.
pub fn parseServerHello(payload: []const u8) error{InvalidServerHello}!ServerHello {
    var fields = std.mem.splitScalar(u8, payload, 0);
    const version_text = fields.next() orelse return error.InvalidServerHello;
    const time = fields.next() orelse return error.InvalidServerHello;
    const version = std.fmt.parseInt(u32, version_text, 10) catch return error.InvalidServerHello;
    return .{ .server_version = version, .connection_time = time };
}

/// Reads one length-prefixed frame and returns its payload. The payload is
/// stored in `buf`, which is reused between calls and owned by the caller.
pub fn readFrame(r: *Reader, gpa: Allocator, buf: *std.ArrayList(u8)) ReadError![]u8 {
    const len = try r.takeInt(u32, .big);
    if (len > max_frame_len) return error.FrameTooLarge;
    try buf.resize(gpa, len);
    try r.readSliceAll(buf.items);
    return buf.items;
}

/// Splits a frame payload into the message id and body.
pub fn parseMessage(payload: []const u8) error{FrameTooShort}!Message {
    if (payload.len < 4) return error.FrameTooShort;
    const raw = std.mem.readInt(u32, payload[0..4], .big);
    const protobuf = raw > protobuf_id_offset;
    return .{
        .id = @fromBackingInt(@intCast(if (protobuf) raw - protobuf_id_offset else raw)),
        .protobuf = protobuf,
        .body = payload[4..],
    };
}

/// Reads one message frame. The body borrows from `buf` and is valid until
/// the next call that uses the same buffer.
pub fn readMessage(r: *Reader, gpa: Allocator, buf: *std.ArrayList(u8)) ReadError!Message {
    return parseMessage(try readFrame(r, gpa, buf));
}

/// Writes one frame with a protobuf body that is already encoded. Does not flush.
pub fn writeMessage(w: *Writer, id: OutMsg, body: []const u8) WriteError!void {
    return writeRawMessage(w, @backingInt(id) + protobuf_id_offset, body);
}

/// Writes one frame with the message id exactly as given (including any
/// protobuf offset). Useful for servers and tests. Does not flush.
pub fn writeRawMessage(w: *Writer, raw_id: u32, body: []const u8) WriteError!void {
    const len = body.len + 4;
    if (len > max_frame_len) return error.FrameTooLarge;
    try w.writeInt(u32, @intCast(len), .big);
    try w.writeInt(u32, raw_id, .big);
    try w.writeAll(body);
}

/// Encodes a generated protobuf message and writes it as one frame.
/// `gpa` is used for temporary buffers only. Does not flush.
pub fn writeProtobuf(w: *Writer, gpa: Allocator, id: OutMsg, msg: anytype) (WriteError || Allocator.Error)!void {
    var body: Writer.Allocating = .init(gpa);
    defer body.deinit();
    msg.encode(&body.writer, gpa) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory, // Allocating writer only fails on OOM.
        else => |e| return e,
    };
    try writeMessage(w, id, body.written());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "hello offers the supported version range" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHello(&out.writer);
    try testing.expectEqualSlices(u8, "API\x00\x00\x00\x00\x09v100..226", out.written());
}

test "server hello is parsed" {
    const hello = try parseServerHello("213\x0020261118 16:54:00 Europe/Prague\x00");
    try testing.expectEqual(@as(u32, 213), hello.server_version);
    try testing.expectEqualStrings("20261118 16:54:00 Europe/Prague", hello.connection_time);

    try testing.expectError(error.InvalidServerHello, parseServerHello("abc\x00x\x00"));
    try testing.expectError(error.InvalidServerHello, parseServerHello("213"));
}

test "message frames round-trip" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMessage(&out.writer, .req_current_time, "\x08\x01");
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x06\x00\x00\x00\xf9\x08\x01", out.written());

    var r: Reader = .fixed(out.written());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const msg = try readMessage(&r, testing.allocator, &buf);
    // The same number means `current_time` in the incoming id space.
    try testing.expectEqual(InMsg.current_time, msg.id);
    try testing.expect(msg.protobuf);
    try testing.expectEqualSlices(u8, "\x08\x01", msg.body);
}

test "text messages are recognised" {
    const msg = try parseMessage("\x00\x00\x00\x2f" ++ "1\x00");
    try testing.expectEqual(@as(u32, 47), @backingInt(msg.id));
    try testing.expect(!msg.protobuf);
}

test "oversized and truncated frames are rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    var big: Reader = .fixed("\x01\x00\x00\x00");
    try testing.expectError(error.FrameTooLarge, readFrame(&big, testing.allocator, &buf));

    var truncated: Reader = .fixed("\x00\x00\x00\x08\x00\x00");
    try testing.expectError(error.EndOfStream, readFrame(&truncated, testing.allocator, &buf));

    try testing.expectError(error.FrameTooShort, parseMessage("\x00\x01"));
}
