//! A scripted stand-in for TWS used by tests. It listens on an ephemeral
//! loopback port; a test script accepts one connection and exchanges
//! messages with the client under test.

const FakeServer = @This();

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const proto = @import("ibapi_proto");
const wire = @import("wire.zig");

server: net.Server,
port: u16,

/// Starts listening on 127.0.0.1 with an ephemeral port.
pub fn listen(io: Io) !FakeServer {
    var address = try net.IpAddress.parse("127.0.0.1", 0);
    const server = try address.listen(io, .{ .reuse_address = true });
    return .{ .server = server, .port = server.socket.address.getPort() };
}

/// Stops listening.
pub fn deinit(s: *FakeServer, io: Io) void {
    s.server.deinit(io);
}

/// Accepts one client connection. Free with `Conn.deinit`.
pub fn accept(s: *FakeServer, io: Io, gpa: Allocator) !*Conn {
    const stream = try s.server.accept(io);
    const conn = try gpa.create(Conn);
    conn.* = .{
        .io = io,
        .gpa = gpa,
        .stream = stream,
        .reader = undefined,
        .writer = undefined,
        .read_buffer = undefined,
        .write_buffer = undefined,
        .frame = .empty,
    };
    conn.reader = stream.reader(io, &conn.read_buffer);
    conn.writer = stream.writer(io, &conn.write_buffer);
    return conn;
}

/// One accepted connection.
pub const Conn = struct {
    io: Io,
    gpa: Allocator,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    frame: std.ArrayList(u8),

    /// A request received from the client.
    pub const Request = struct {
        id: wire.OutMsg,
        body: []const u8,

        /// Decodes the body as protobuf message `T`; free with `T.deinit`.
        pub fn decode(req: Request, comptime T: type, gpa: Allocator) !T {
            var r: std.Io.Reader = .fixed(req.body);
            return T.decode(&r, gpa);
        }
    };

    /// Closes the connection.
    pub fn deinit(conn: *Conn) void {
        conn.stream.close(conn.io);
        conn.frame.deinit(conn.gpa);
        conn.gpa.destroy(conn);
    }

    /// Reads the client's hello and checks the offered versions.
    pub fn expectHello(conn: *Conn) !void {
        const r = &conn.reader.interface;
        const prefix = try r.takeArray(4);
        try std.testing.expectEqualSlices(u8, "API\x00", prefix);
        const payload = try wire.readFrame(r, conn.gpa, &conn.frame);
        try std.testing.expectEqualStrings("v100..226", payload);
    }

    /// Sends the server hello with the given version.
    pub fn sendHello(conn: *Conn, server_version: u32) !void {
        var buf: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{d}\x0020261118 16:54:00 Europe/Prague\x00", .{server_version});
        const w = &conn.writer.interface;
        try w.writeInt(u32, @intCast(payload.len), .big);
        try w.writeAll(payload);
        try w.flush();
    }

    /// Performs the server side of a successful handshake: hello, StartApi
    /// (checking the client id), managed accounts, one informational error
    /// notice and the next valid order id.
    pub fn handshake(conn: *Conn, client_id: i32) !void {
        try conn.expectHello();
        try conn.sendHello(wire.max_client_version);

        const req = try conn.readRequest();
        try std.testing.expectEqual(wire.OutMsg.start_api, req.id);
        var start = try req.decode(proto.StartApiRequest, conn.gpa);
        defer start.deinit(conn.gpa);
        try std.testing.expectEqual(@as(?i32, client_id), start.clientId);

        try conn.send(.managed_accounts, proto.ManagedAccounts{ .accountsList = "DU0000001" });
        try conn.send(.error_message, proto.ErrorMessage{
            .id = -1,
            .errorCode = 2104,
            .errorMsg = "Market data farm connection is OK:usfarm",
        });
        try conn.send(.next_valid_id, proto.NextValidId{ .orderId = 1 });
    }

    /// Reads the next request. The body is valid until the next read.
    pub fn readRequest(conn: *Conn) !Request {
        const msg = try wire.readMessage(&conn.reader.interface, conn.gpa, &conn.frame);
        try std.testing.expect(msg.protobuf);
        return .{ .id = @fromBackingInt(@intCast(@backingInt(msg.id))), .body = msg.body };
    }

    /// Sends a protobuf message as the server would.
    pub fn send(conn: *Conn, id: wire.InMsg, msg: anytype) !void {
        var body: std.Io.Writer.Allocating = .init(conn.gpa);
        defer body.deinit();
        try msg.encode(&body.writer, conn.gpa);
        const w = &conn.writer.interface;
        try wire.writeRawMessage(w, @backingInt(id) + wire.protobuf_id_offset, body.written());
        try w.flush();
    }

    /// Waits until the client closes the connection.
    pub fn expectClose(conn: *Conn) !void {
        while (true) {
            _ = wire.readMessage(&conn.reader.interface, conn.gpa, &conn.frame) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return, // connection reset counts as closed
                else => return err,
            };
        }
    }
};
