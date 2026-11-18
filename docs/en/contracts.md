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

## Example program

`examples/contracts.zig`:

```sh
zig build examples
./zig-out/bin/contracts search apple
./zig-out/bin/contracts details AAPL
./zig-out/bin/contracts details AAPL OPT USD 20261218
```
