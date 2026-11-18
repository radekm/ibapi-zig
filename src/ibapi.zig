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
