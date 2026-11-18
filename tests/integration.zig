//! Opt-in integration test against a running TWS / IB Gateway logged in to
//! a **paper trading** account: `zig build test-integration`.
//!
//! Connection: IBAPI_HOST (default 127.0.0.1), IBAPI_PORT (default 7497) and
//! IBAPI_CLIENT_ID (default 17). The test refuses to run unless every
//! managed account is a paper account (ids starting with "D").
//!
//! Only read-only requests are sent. Steps that need market data
//! subscriptions are reported as skipped when TWS rejects them.

const std = @import("std");
const ibapi = @import("ibapi");
const Client = ibapi.Client;
const Query = ibapi.contract.Query;

const Outcome = enum { ok, skipped, failed };

const Runner = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    client: *Client,
    failed: usize = 0,

    fn report(r: *Runner, name: []const u8, outcome: Outcome, comptime fmt: []const u8, args: anytype) void {
        if (outcome == .failed) r.failed += 1;
        std.debug.print("[{t:<7}] {s}: " ++ fmt ++ "\n", .{ outcome, name } ++ args);
    }
};

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const host = env.get("IBAPI_HOST") orelse "127.0.0.1";
    const port = if (env.get("IBAPI_PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 7497;
    const client_id = if (env.get("IBAPI_CLIENT_ID")) |id| try std.fmt.parseInt(i32, id, 10) else 17;

    const client = try Client.connect(init.io, init.gpa, .{ .host = host, .port = port, .client_id = client_id });
    defer client.close();
    std.debug.print("connected: server version {d}, time {s}\n", .{ client.serverVersion(), client.connectionTime() });

    try requirePaperAccounts(client.managedAccounts());

    var r: Runner = .{ .io = init.io, .gpa = init.gpa, .client = client };
    unsolicitedAfterConnect(&r);
    currentTime(&r);
    const con_id = contractDetails(&r);
    searchSymbols(&r);
    if (con_id) |id| {
        optionChain(&r, id);
        snapshot(&r, id);
    }
    openOrders(&r);
    completedOrders(&r);

    std.debug.print("{d} failed, {d} notices dropped\n", .{ r.failed, client.droppedNotices() });
    if (r.failed > 0) return error.IntegrationTestFailed;
}

/// Paper accounts have ids starting with "D" (e.g. DU…, DF…).
fn requirePaperAccounts(accounts: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, accounts, ',');
    var any = false;
    while (it.next()) |account| {
        any = true;
        if (account[0] != 'D') {
            std.debug.print("refusing to run: not a paper trading login\n", .{});
            return error.NotPaperAccount;
        }
    }
    if (!any) return error.NoManagedAccounts;
}

/// Records what TWS sends on its own right after connecting (open question
/// in PLAN.md: does it send open orders and OpenOrderEnd unasked?).
fn unsolicitedAfterConnect(r: *Runner) void {
    var count: usize = 0;
    while (true) {
        var msg = (r.client.nextNotice(.{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }) catch break) orelse break;
        defer msg.deinit(r.gpa);
        count += 1;
        const id = msg.msgId();
        const name = std.enums.tagName(ibapi.wire.InMsg, id) orelse "?";
        switch (msg) {
            .error_message => |e| std.debug.print("  notice {s}: {?d} {s}\n", .{ name, e.errorCode, e.errorMsg orelse "" }),
            else => std.debug.print("  notice {s} ({d})\n", .{ name, @backingInt(id) }),
        }
    }
    r.report("notices after connect", .ok, "{d} (listed above)", .{count});
}

fn currentTime(r: *Runner) void {
    const t = r.client.currentTime() catch |err| return r.report("currentTime", .failed, "{t}", .{err});
    r.report("currentTime", .ok, "{d}", .{t});
}

fn contractDetails(r: *Runner) ?i32 {
    var diag: Client.Diagnostics = .{};
    var list = r.client.contractDetails(r.gpa, Query.stock("AAPL", "USD"), .{ .diagnostics = &diag }) catch |err| {
        r.report("contractDetails AAPL", .failed, "{t} {d} {s}", .{ err, diag.code, diag.message() });
        return null;
    };
    defer list.deinit();
    if (list.items.len == 0) {
        r.report("contractDetails AAPL", .failed, "no contracts", .{});
        return null;
    }
    const id = list.items[0].contract.?.conId;
    r.report("contractDetails AAPL", .ok, "{d} contracts, con id {?d}", .{ list.items.len, id });

    var none_diag: Client.Diagnostics = .{};
    if (r.client.contractDetails(r.gpa, Query.stock("NO SUCH SYMBOL", "USD"), .{ .diagnostics = &none_diag })) |l| {
        var l2 = l;
        l2.deinit();
        r.report("contractDetails unknown", .failed, "expected a rejection", .{});
    } else |err| {
        const ok = err == error.RequestRejected and none_diag.code == 200;
        r.report("contractDetails unknown", if (ok) .ok else .failed, "{t} {d}", .{ err, none_diag.code });
    }
    return id;
}

fn searchSymbols(r: *Runner) void {
    var m = r.client.searchSymbols(r.gpa, "AAP", .{}) catch |err| return r.report("searchSymbols", .failed, "{t}", .{err});
    defer m.deinit();
    r.report("searchSymbols", if (m.items().len > 0) .ok else .failed, "{d} matches", .{m.items().len});
}

fn optionChain(r: *Runner, con_id: i32) void {
    var chain = r.client.optionChainParams(r.gpa, .{ .symbol = "AAPL", .con_id = con_id }, .{}) catch |err|
        return r.report("optionChainParams", .failed, "{t}", .{err});
    defer chain.deinit();
    if (chain.items.len == 0) return r.report("optionChainParams", .failed, "empty", .{});
    const first = chain.items[0];
    r.report("optionChainParams", .ok, "{d} exchanges, {d} expirations", .{ chain.items.len, first.expirations.items.len });

    // Strikes of the first expiration (calls only).
    if (first.expirations.items.len == 0) return;
    const expiry = first.expirations.items[0];
    var calls = r.client.contractDetails(r.gpa, Query.option("AAPL", "USD", expiry, null, .call), .{ .timeout = .fromSeconds(60) }) catch |err|
        return r.report("contractDetails options", .failed, "{s}: {t}", .{ expiry, err });
    defer calls.deinit();
    r.report("contractDetails options", if (calls.items.len > 0) .ok else .failed, "{s}: {d} calls", .{ expiry, calls.items.len });
}

fn snapshot(r: *Runner, con_id: i32) void {
    var diag: Client.Diagnostics = .{};
    const q = r.client.snapshot(Query.byConId(con_id, "SMART"), .{ .diagnostics = &diag }) catch |err| switch (err) {
        error.RequestRejected => return r.report("snapshot", .skipped, "TWS error {d}: {s}", .{ diag.code, diag.message() }),
        else => return r.report("snapshot", .failed, "{t}", .{err}),
    };
    r.report("snapshot", .ok, "{?t} bid {?d} ask {?d} last {?d} close {?d}", .{ q.data_type, q.bid, q.ask, q.last, q.close });
}

fn openOrders(r: *Runner) void {
    var list = r.client.openOrders(r.gpa, .{}) catch |err| return r.report("openOrders", .failed, "{t}", .{err});
    defer list.deinit();
    var without_status: usize = 0;
    for (list.items) |o| {
        if (o.status == null) without_status += 1;
    }
    r.report("openOrders", .ok, "{d} orders, {d} without a status update", .{ list.items.len, without_status });
}

fn completedOrders(r: *Runner) void {
    var list = r.client.completedOrders(r.gpa, .{}) catch |err| return r.report("completedOrders", .failed, "{t}", .{err});
    defer list.deinit();
    r.report("completedOrders", .ok, "{d} orders", .{list.items.len});
}
