//! A bounded multi-producer, multi-consumer queue whose `get` takes a timeout.
//!
//! `std.Io.Queue` cannot time out, which the client needs for every request.

const std = @import("std");
const Io = std.Io;

/// Returns a mailbox type for elements of type `T`, backed by a caller-owned buffer.
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Io.Mutex = .init,
        not_empty: Io.Condition = .init,
        not_full: Io.Condition = .init,
        buffer: []T,
        start: usize = 0,
        len: usize = 0,
        closed: bool = false,

        /// Errors of `get`.
        pub const GetError = error{ Closed, Timeout } || Io.Cancelable;
        /// Errors of `put`.
        pub const PutError = error{Closed} || Io.Cancelable;

        /// Creates an empty, open mailbox storing at most `buffer.len` elements.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Adds `item`, waiting while the mailbox is full. Fails with
        /// `error.Closed` if the mailbox is or becomes closed; then `item`
        /// stays owned by the caller.
        pub fn put(m: *Self, io: Io, item: T) PutError!void {
            try m.mutex.lock(io);
            defer m.mutex.unlock(io);
            while (!m.closed and m.len == m.buffer.len) try m.not_full.wait(io, &m.mutex);
            if (m.closed) return error.Closed;
            m.pushLocked(io, item);
        }

        /// Adds `item` if there is room and the mailbox is open; never waits.
        pub fn tryPut(m: *Self, io: Io, item: T) bool {
            m.mutex.lockUncancelable(io);
            defer m.mutex.unlock(io);
            if (m.closed or m.len == m.buffer.len) return false;
            m.pushLocked(io, item);
            return true;
        }

        fn pushLocked(m: *Self, io: Io, item: T) void {
            m.buffer[(m.start + m.len) % m.buffer.len] = item;
            m.len += 1;
            m.not_empty.signal(io);
        }

        /// Removes the oldest element. Elements put before `close` are still
        /// returned; afterwards `error.Closed`.
        pub fn get(m: *Self, io: Io, timeout: Io.Timeout) GetError!T {
            const deadline = timeout.toDeadline(io);
            try m.mutex.lock(io);
            defer m.mutex.unlock(io);
            while (m.len == 0) {
                if (m.closed) return error.Closed;
                try m.not_empty.waitTimeout(io, &m.mutex, deadline);
            }
            const item = m.buffer[m.start];
            m.start = (m.start + 1) % m.buffer.len;
            m.len -= 1;
            m.not_full.signal(io);
            return item;
        }

        /// Like `get` but returns null instead of waiting when empty.
        pub fn tryGet(m: *Self, io: Io) ?T {
            m.mutex.lockUncancelable(io);
            defer m.mutex.unlock(io);
            if (m.len == 0) return null;
            const item = m.buffer[m.start];
            m.start = (m.start + 1) % m.buffer.len;
            m.len -= 1;
            m.not_full.signal(io);
            return item;
        }

        /// Rejects further `put`s and wakes all waiters. Idempotent.
        pub fn close(m: *Self, io: Io) void {
            m.mutex.lockUncancelable(io);
            defer m.mutex.unlock(io);
            m.closed = true;
            m.not_empty.broadcast(io);
            m.not_full.broadcast(io);
        }
    };
}

const testing = std.testing;

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

test "elements come out in order and get times out when empty" {
    const io = testing.io;
    var buf: [2]u32 = undefined;
    var m: Mailbox(u32) = .init(&buf);
    try m.put(io, 1);
    try testing.expect(m.tryPut(io, 2));
    try testing.expect(!m.tryPut(io, 3)); // full
    try testing.expectEqual(@as(u32, 1), try m.get(io, .none));
    try testing.expectEqual(@as(u32, 2), try m.get(io, .none));
    try testing.expectError(error.Timeout, m.get(io, ms(20)));
}

test "close drains remaining elements, then reports Closed" {
    const io = testing.io;
    var buf: [2]u32 = undefined;
    var m: Mailbox(u32) = .init(&buf);
    try m.put(io, 7);
    m.close(io);
    try testing.expectError(error.Closed, m.put(io, 8));
    try testing.expectEqual(@as(u32, 7), try m.get(io, .none));
    try testing.expectError(error.Closed, m.get(io, ms(1000)));
}

fn putLater(m: *Mailbox(u32)) !void {
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try m.put(testing.io, 42);
}

test "a waiting get is woken by put from another task" {
    const io = testing.io;
    var buf: [1]u32 = undefined;
    var m: Mailbox(u32) = .init(&buf);
    var task = try io.concurrent(putLater, .{&m});
    defer task.cancel(io) catch {};
    try testing.expectEqual(@as(u32, 42), try m.get(io, ms(5000)));
    try task.await(io);
}

fn closeLater(m: *Mailbox(u32)) !void {
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    m.close(testing.io);
}

test "close wakes a blocked put" {
    const io = testing.io;
    var buf: [1]u32 = undefined;
    var m: Mailbox(u32) = .init(&buf);
    try m.put(io, 1);
    var task = try io.concurrent(closeLater, .{&m});
    defer task.cancel(io) catch {};
    try testing.expectError(error.Closed, m.put(io, 2));
    try task.await(io);
}
