//! A message received from the server, decoded into its protobuf type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("ibapi_proto");
const wire = @import("wire.zig");

/// Decoded incoming message. Each variant is named after the `wire.InMsg`
/// tag of its message id; this is checked at compile time.
///
/// Memory of the payload is owned by the receiver and released with `deinit`.
pub const Incoming = union(enum) {
    error_message: proto.ErrorMessage,
    next_valid_id: proto.NextValidId,
    managed_accounts: proto.ManagedAccounts,
    current_time: proto.CurrentTime,
    current_time_in_millis: proto.CurrentTimeInMillis,
    contract_data: proto.ContractData,
    /// Same payload as `contract_data`, sent for bonds.
    bond_contract_data: proto.ContractData,
    contract_data_end: proto.ContractDataEnd,
    symbol_samples: proto.SymbolSamples,
    sec_def_opt_parameter: proto.SecDefOptParameter,
    sec_def_opt_parameter_end: proto.SecDefOptParameterEnd,
    tick_price: proto.TickPrice,
    tick_size: proto.TickSize,
    tick_string: proto.TickString,
    tick_generic: proto.TickGeneric,
    tick_option_computation: proto.TickOptionComputation,
    tick_req_params: proto.TickReqParams,
    tick_snapshot_end: proto.TickSnapshotEnd,
    market_data_type: proto.MarketDataType,
    open_order: proto.OpenOrder,
    order_status: proto.OrderStatus,
    open_order_end: proto.OpenOrdersEnd,
    completed_order: proto.CompletedOrder,
    completed_orders_end: proto.CompletedOrdersEnd,
    historical_data: proto.HistoricalData,
    historical_data_end: proto.HistoricalDataEnd,
    /// A message this version of the library does not decode.
    other: Other,

    /// Identification of a message that was not decoded.
    pub const Other = struct {
        id: wire.InMsg,
        /// False if the server sent the message in the legacy text format.
        protobuf: bool,
    };

    comptime {
        for (@typeInfo(Incoming).@"union".field_names) |name| {
            if (!std.mem.eql(u8, name, "other") and !@hasField(wire.InMsg, name)) {
                @compileError("Incoming." ++ name ++ " has no matching wire.InMsg id");
            }
        }
    }

    /// Releases memory owned by the message.
    pub fn deinit(self: *Incoming, gpa: Allocator) void {
        switch (self.*) {
            .other => {},
            inline else => |*m| m.deinit(gpa),
        }
        self.* = undefined;
    }

    /// Message id of the message.
    pub fn msgId(self: Incoming) wire.InMsg {
        return switch (self) {
            .other => |o| o.id,
            inline else => |_, tag| @field(wire.InMsg, @tagName(tag)),
        };
    }

    /// Id of the request the message answers, if the message carries one.
    /// For `error_message` this is its `id` field; `-1` means no request.
    pub fn requestId(self: Incoming) ?i32 {
        return switch (self) {
            .other => null,
            .error_message => |m| if (m.id) |id| (if (id >= 0) id else null) else null,
            inline else => |m| if (@hasField(@TypeOf(m), "reqId")) m.reqId else null,
        };
    }

    /// Decodes the body of `msg`. Messages without a matching variant, and
    /// messages in the legacy text format, become `.other`.
    pub fn decode(gpa: Allocator, msg: wire.Message) !Incoming {
        if (msg.protobuf) {
            const info = @typeInfo(Incoming).@"union";
            inline for (info.field_names, info.field_types) |name, T| {
                if (comptime std.mem.eql(u8, name, "other")) continue;
                if (msg.id == @field(wire.InMsg, name)) {
                    var r: std.Io.Reader = .fixed(msg.body);
                    return @unionInit(Incoming, name, try T.decode(&r, gpa));
                }
            }
        }
        return .{ .other = .{ .id = msg.id, .protobuf = msg.protobuf } };
    }
};

const testing = std.testing;

test "decodes a known protobuf message and reports its ids" {
    const gpa = testing.allocator;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const sent: proto.ErrorMessage = .{ .id = 12, .errorCode = 200, .errorMsg = "No security definition" };
    try sent.encode(&body.writer, gpa);

    var inc = try Incoming.decode(gpa, .{ .id = .error_message, .protobuf = true, .body = body.written() });
    defer inc.deinit(gpa);

    try testing.expectEqual(wire.InMsg.error_message, inc.msgId());
    try testing.expectEqual(@as(?i32, 12), inc.requestId());
    try testing.expectEqualStrings("No security definition", inc.error_message.errorMsg.?);
}

test "unknown and text messages become .other" {
    const gpa = testing.allocator;
    const unknown = try Incoming.decode(gpa, .{ .id = @fromBackingInt(@intCast(999)), .protobuf = true, .body = "" });
    try testing.expectEqual(@as(u32, 999), @backingInt(unknown.msgId()));

    const text = try Incoming.decode(gpa, .{ .id = .current_time, .protobuf = false, .body = "1\x00" });
    try testing.expect(!text.other.protobuf);
    try testing.expectEqual(@as(?i32, null), text.requestId());
}

test "errors without a request id are not routed" {
    const inc: Incoming = .{ .error_message = .{ .id = -1, .errorCode = 2104 } };
    try testing.expectEqual(@as(?i32, null), inc.requestId());
}
