# Looking up contracts

[Česká verze](../cs/contracts.md)

A contract (instrument) is described by `ibapi.contract.Query`. Fields left
`null` are not sent, so one query can match many contracts.

```zig
const Query = ibapi.contract.Query;

Query.stock("AAPL", "USD")                          // AAPL routed via SMART
Query.option("AAPL", "USD", "20261218", 200, .call) // one option
Query.option("AAPL", "USD", "20261218", null, null) // all options of an expiration
Query.future("ES", "CME", "USD", null)              // all ES futures
Query.index("SPX", "CBOE", "USD")
Query.forex("EUR", "USD")                            // EUR.USD on IDEALPRO
Query.byConId(265598, "SMART")                       // by IB contract id
```

Any other field can be set directly, e.g.
`.{ .sec_id_type = "ISIN", .sec_id = "US0378331005", .sec_type = .stock }`.

## Contract details

```zig
var list = try client.contractDetails(gpa, Query.stock("AAPL", "USD"), .{});
defer list.deinit();
for (list.items) |item| {
    const c = item.contract.?;          // ibapi.proto.Contract
    const d = item.contractDetails.?;   // ibapi.proto.ContractDetails
    std.debug.print("{?d} {s} {s}\n", .{ c.conId, c.primaryExch orelse "", d.longName orelse "" });
}
```

The `conId` from the result identifies the contract uniquely and is the best
way to refer to it in later requests (`Query.byConId`).

When nothing matches, TWS answers with error 200 and the call fails with
`error.RequestRejected`. Pass a `Diagnostics` to see the code and message:

```zig
var diag: ibapi.Client.Diagnostics = .{};
_ = client.contractDetails(gpa, query, .{ .diagnostics = &diag }) catch |err| switch (err) {
    error.RequestRejected => std.debug.print("TWS error {d}: {s}\n", .{ diag.code, diag.message() }),
    else => return err,
};
```

A query that matches all options of a symbol returns thousands of contracts
and can take tens of seconds; raise the limit with `.{ .timeout = .fromSeconds(60) }`.
If the request times out, the library asks TWS to stop sending the rest.

## Symbol search

```zig
var matches = try client.searchSymbols(gpa, "apple", .{});
defer matches.deinit();
for (matches.items()) |m| { ... m.contract, m.derivativeSecTypes ... }
```

The pattern is matched against the beginning of symbols and against company
names. TWS returns at most a few dozen matches.

## Option chains

`optionChainParams` returns, for each exchange and trading class of the
options on an underlying, the multiplier, all expirations and all strikes.
It is one short answer even for symbols with thousands of options.

```zig
var chain = try client.optionChainParams(gpa, .{ .symbol = "AAPL", .con_id = 265598 }, .{});
defer chain.deinit();
for (chain.items) |p| {
    // p.exchange, p.tradingClass, p.multiplier,
    // p.expirations.items ([]const u8, YYYYMMDD), p.strikes.items (f64)
}
```

The underlying's `con_id` is required; get it from `contractDetails`.
For indices and futures set `.sec_type = .index` / `.future`. Some
underlyings have several trading classes, e.g. `SPX` (monthly) and `SPXW`
(weeklies).

**The strikes are the union over all expirations** — a particular expiration
does not have to offer every strike. To get the real strikes of one
expiration, ask for its contracts; calls are enough for stock options:

```zig
var calls = try client.contractDetails(gpa,
    Query.option("AAPL", "USD", "20261218", null, .call), .{ .timeout = .fromSeconds(30) });
defer calls.deinit();
// calls.items[i].contract.?.strike, .conId
```

TWS cannot filter by a range of dates. To work with, say, expirations within
45 days, take the expirations from `optionChainParams`, choose the ones you
need and ask for contract details of each of them.
`examples/option_chain.zig` shows exactly this.

## Example programs

`examples/contracts.zig` and `examples/option_chain.zig`:

```sh
zig build examples
./zig-out/bin/contracts search apple
./zig-out/bin/contracts details AAPL
./zig-out/bin/contracts details AAPL OPT USD 20261218
./zig-out/bin/option_chain AAPL 45
```
