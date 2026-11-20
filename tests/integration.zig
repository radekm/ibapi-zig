//! Opt-in integration test against a running TWS / IB Gateway logged in to
//! a **paper trading** account: `zig build test-integration`.
//!
//! Connection: `Config.zon` in the current working directory, as for the
//! examples (see examples/Config.example.zon). The test refuses to run unless every
//! managed account id starts with "D", as paper accounts do (DU…, DF…).
//! IB does not document this prefix; it is a safety net, not a guarantee.
//!
//! Only read-only requests are sent. The test must pass on a paper account
//! without paid market data: historical bars of AAPL are required (without
//! a subscription TWS returns them delayed, with warning 2188), the AAPL
//! snapshot and the EUR.USD bars are reported as skipped when TWS rejects
//! them (a snapshot needs a subscription; free forex data needs forex
//! trading permissions).

const std = @import("std");
const ibapi = @import("ibapi");
const common = @import("common");
const Client = ibapi.Client;
const Query = ibapi.contract.Query;

const Outcome = enum { ok, skipped, failed };

/// Whether a step may be skipped when TWS rejects it (missing market data
/// subscription) or must succeed.
const Need = enum {
    optional,
    required,

    fn rejected(n: Need) Outcome {
        return if (n == .optional) .skipped else .failed;
    }
};

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
    const client = try common.connectFromConfig(init);
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
        const aapl = Query.byConId(id, "SMART");
        snapshot(&r, "AAPL", aapl, .optional);
        historicalBars(&r, "AAPL", aapl, .trades, .required);
    }
    // Forex has no trades, so bars are built from midpoints. No snapshot:
    // without forex permissions TWS did not answer it at all (timeout)
    // instead of rejecting it.
    historicalBars(&r, "EUR.USD", Query.forex("EUR", "USD"), .midpoint, .optional);
    openOrders(&r);
    completedOrders(&r);

    std.debug.print("{d} failed, {d} notices dropped\n", .{ r.failed, client.droppedNotices() });
    if (r.failed > 0) return error.IntegrationTestFailed;
}

/// Paper accounts have ids starting with "D" (e.g. DU…, DF…). IB does not
/// document this, so it is only a safety net against a live login.
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
    const id = if (list.items[0].contract) |c| c.conId else null;
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

fn snapshot(r: *Runner, label: []const u8, query: Query, need: Need) void {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "snapshot {s}", .{label}) catch "snapshot";
    var diag: Client.Diagnostics = .{};
    const q = r.client.snapshot(query, .{ .diagnostics = &diag }) catch |err| switch (err) {
        error.RequestRejected => return r.report(name, need.rejected(), "TWS error {d}: {s}", .{ diag.code, diag.message() }),
        else => return r.report(name, .failed, "{t}", .{err}),
    };
    r.report(name, .ok, "{s} bid {?d} ask {?d} last {?d} close {?d}", .{ if (q.data_type) |t| t.name() else "?", q.bid, q.ask, q.last, q.close });
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

fn printBarTime(label: []const u8, t: std.Io.Timestamp) void {
    var buf: [17]u8 = undefined;
    std.debug.print("  {s} {s} UTC\n", .{ label, ibapi.history.formatUtc(&buf, @intCast(ibapi.history.floorSeconds(t))) });
}

/// Minute bars of the last 2 hours and of the last 3 days (several
/// requests), daily bars of the last 30 days. Prints the boundary bars, so
/// that the handling of `endDateTime` can be checked (open question in
/// PLAN.md). The last 2 hours may have no bars (weekend, closed market);
/// 3 days of minutes and 30 days must have some.
fn historicalBars(r: *Runner, label: []const u8, query: Query, what: ibapi.history.WhatToShow, need: Need) void {
    const history = ibapi.history;
    const now = std.Io.Timestamp.now(r.io, .real);
    var diag: Client.Diagnostics = .{};
    var name_buf: [64]u8 = undefined;

    for ([_]struct { []const u8, i64, bool }{ .{ "2 h", 2 * 3600, false }, .{ "3 days", 3 * 86400, true } }) |step| {
        const name = std.fmt.bufPrint(&name_buf, "minuteBars {s} {s}", .{ label, step[0] }) catch "minuteBars";
        var bars = r.client.minuteBars(r.gpa, query, .{
            .start = now.subDuration(.fromSeconds(step[1])),
            .what_to_show = what,
            .use_rth = false,
        }, .{ .diagnostics = &diag }) catch |err| switch (err) {
            error.RequestRejected => {
                r.report(name, need.rejected(), "TWS error {d}: {s}", .{ diag.code, diag.message() });
                continue;
            },
            else => {
                r.report(name, .failed, "{t}", .{err});
                continue;
            },
        };
        defer bars.deinit();
        if (bars.items.len > 0) {
            printBarTime("first", bars.items[0].time);
            printBarTime("last ", bars.items[bars.items.len - 1].time);
        }
        const ok = bars.items.len > 0 or !step[2];
        r.report(name, if (ok) .ok else .failed, "{d} bars", .{bars.items.len});
    }

    const name = std.fmt.bufPrint(&name_buf, "dailyBars {s} 30 days", .{label}) catch "dailyBars";
    const today = @divFloor(history.floorSeconds(now), std.time.s_per_day);
    var days = r.client.dailyBars(r.gpa, query, .{
        .first = .{ .day = @intCast(today - 30) },
        .what_to_show = what,
    }, .{ .diagnostics = &diag }) catch |err| switch (err) {
        error.RequestRejected => return r.report(name, need.rejected(), "TWS error {d}: {s}", .{ diag.code, diag.message() }),
        else => return r.report(name, .failed, "{t}", .{err}),
    };
    defer days.deinit();
    r.report(name, if (days.items.len > 0) .ok else .failed, "{d} bars", .{days.items.len});
}
