//! A TCP stream whose reads and writes honour deadlines.
//!
//! `std.Io.net.Stream.Reader` / `Writer` wait forever; this type implements
//! the same `std.Io.Reader` / `std.Io.Writer` interfaces on top of
//! `Io.operateTimeout`, so every socket operation can be bounded.

const Transport = @This();

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

io: Io,
stream: net.Stream,
/// Buffered reader; reads fail with `read_err == error.Timeout` after `read_timeout`.
reader: Io.Reader,
/// Buffered writer; flushes fail with `write_err == error.Timeout` after `write_timeout`.
writer: Io.Writer,
/// Applies to every read. Use a deadline to bound a sequence of reads.
read_timeout: Io.Timeout = .none,
/// Applies to every write. Use a deadline to bound a sequence of writes.
write_timeout: Io.Timeout = .none,
/// Cause of the last `error.ReadFailed`.
read_err: ?Error = null,
/// Cause of the last `error.WriteFailed`.
write_err: ?Error = null,

/// Why a socket operation failed.
pub const Error = error{
    /// The operation did not finish before its timeout.
    Timeout,
    /// The task was canceled.
    Canceled,
    /// `io` cannot run operations with a timeout.
    ConcurrencyUnavailable,
    /// Any other socket error; the connection is unusable.
    SocketFailed,
};

/// Wraps a connected stream. `t` must stay at a fixed address while in use.
pub fn init(t: *Transport, io: Io, stream: net.Stream, read_buffer: []u8, write_buffer: []u8) void {
    t.* = .{
        .io = io,
        .stream = stream,
        .reader = .{
            .vtable = &.{ .stream = streamImpl, .readVec = readVec },
            .buffer = read_buffer,
            .seek = 0,
            .end = 0,
        },
        .writer = .{
            .vtable = &.{ .drain = drain },
            .buffer = write_buffer,
        },
    };
}

/// Closes the socket.
pub fn close(t: *Transport) void {
    t.stream.close(t.io);
}

fn mapOperateError(err: Io.OperateTimeoutError) Error {
    return switch (err) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
    };
}

fn streamImpl(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try w.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(r, &data);
    w.advance(n);
    return n;
}

fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const t: *Transport = @alignCast(@fieldParentPtr("reader", r));
    var iovecs: [8][]u8 = undefined;
    const dest_n, const data_size = try r.writableVector(&iovecs, data);
    const result = t.io.operateTimeout(.{ .net_read = .{
        .socket_handle = t.stream.socket.handle,
        .data = iovecs[0..dest_n],
    } }, t.read_timeout) catch |err| {
        t.read_err = mapOperateError(err);
        return error.ReadFailed;
    };
    const read = result.net_read catch {
        t.read_err = error.SocketFailed;
        return error.ReadFailed;
    };
    if (read.data_len == 0) return error.EndOfStream;
    if (read.data_len > data_size) {
        r.end += read.data_len - data_size;
        return data_size;
    }
    return read.data_len;
}

fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const t: *Transport = @alignCast(@fieldParentPtr("writer", w));
    const result = t.io.operateTimeout(.{ .net_write = .{
        .socket_handle = t.stream.socket.handle,
        .header = w.buffered(),
        .data = data,
        .splat = splat,
    } }, t.write_timeout) catch |err| {
        t.write_err = mapOperateError(err);
        return error.WriteFailed;
    };
    const n = result.net_write catch {
        t.write_err = error.SocketFailed;
        return error.WriteFailed;
    };
    return w.consume(n);
}

test "reads time out and data still arrives afterwards" {
    const testing = std.testing;
    const io = testing.io;

    var address = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const client_stream = try server.socket.address.connect(io, .{ .mode = .stream });
    const server_stream = try server.accept(io);
    defer server_stream.close(io);

    var rbuf: [64]u8 = undefined;
    var wbuf: [64]u8 = undefined;
    var t: Transport = undefined;
    t.init(io, client_stream, &rbuf, &wbuf);
    defer t.close();

    t.read_timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };
    try testing.expectError(error.ReadFailed, t.reader.takeByte());
    try testing.expectEqual(@as(?Error, error.Timeout), t.read_err);

    var sw = server_stream.writer(io, &.{});
    try sw.interface.writeAll("x");
    try testing.expectEqual(@as(u8, 'x'), try t.reader.takeByte());

    t.write_timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
    try t.writer.writeAll("hello");
    try t.writer.flush();
    var sr_buf: [16]u8 = undefined;
    var sr = server_stream.reader(io, &sr_buf);
    try testing.expectEqualStrings("hello", try sr.interface.take(5));
}
