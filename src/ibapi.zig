//! ibapi-zig — a Zig client for the protobuf TWS API of Interactive Brokers.
//!
//! The library talks to Trader Workstation (TWS) or IB Gateway over TCP.
//! Only the protobuf variant of the protocol is supported, which requires
//! server version 213 or newer (TWS / IB Gateway 10.40+).

const std = @import("std");

/// Types generated from the TWS API `.proto` files (protobuf package `protobuf`).
pub const proto = @import("ibapi_proto");

/// Runtime of zig-protobuf, re-exported so that applications use the same version.
pub const protobuf = @import("protobuf");

/// Framing and handshake of the TWS API.
pub const wire = @import("wire.zig");

/// Asynchronous client of TWS / IB Gateway.
pub const Client = @import("Client.zig");

/// Describing contracts (instruments) for requests.
pub const contract = @import("contract.zig");

/// Market data snapshots (`Client.snapshot`).
pub const market_data = @import("market_data.zig");

/// A decoded message received from the server.
pub const Incoming = @import("incoming.zig").Incoming;

test {
    _ = @import("mailbox.zig");
    _ = @import("Transport.zig");
}

test {
    std.testing.refAllDecls(@This());
}

test "generated StartApiRequest round-trips through protobuf encoding" {
    const gpa = std.testing.allocator;

    const original: proto.StartApiRequest = .{
        .clientId = 7,
        .optionalCapabilities = "",
    };

    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try original.encode(&encoded.writer, gpa);

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try proto.StartApiRequest.decode(&reader, gpa);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(?i32, 7), decoded.clientId);
    try std.testing.expectEqualStrings("", decoded.optionalCapabilities.?);
}
