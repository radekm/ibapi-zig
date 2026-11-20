# Prices of stocks and options

[Česká verze](../cs/prices.md)

ibapi-zig only takes **snapshots**: one request, one answer with the current
values. Streaming subscriptions are deliberately not supported.

```zig
const Query = ibapi.contract.Query;

const stock = try client.snapshot(Query.stock("AAPL", "USD"), .{});
std.debug.print("bid {?d} ask {?d} last {?d}\n", .{ stock.bid, stock.ask, stock.last });

const option = try client.snapshot(Query.option("AAPL", "USD", "20261218", 190, .call), .{});
if (option.model_computation) |m| {
    std.debug.print("iv {?d} delta {?d} theta {?d}\n", .{ m.implied_vol, m.delta, m.theta });
}
```

A contract found by `contractDetails` is best referred to by its id:
`Query.byConId(con_id, "SMART")`.

## What a snapshot contains

`ibapi.market_data.Quote` — every field is optional (`null` when TWS did not
send it):

| Field | Meaning |
| --- | --- |
| `bid`, `bid_size`, `ask`, `ask_size` | best bid and offer |
| `last`, `last_size`, `last_timestamp` | last trade (timestamp in Unix seconds) |
| `open`, `high`, `low` | today |
| `close` | close of the previous trading day |
| `volume` | today's volume |
| `data_type` | `.live` or `.frozen` as reported by TWS (delayed data end the snapshot with `error.RequestRejected`) |
| `bid_computation`, `ask_computation`, `last_computation`, `model_computation` | option values, see below |

`quote.mid()` returns the midpoint of bid and ask.

## Greeks and implied volatility

For options TWS computes the values with **its own option model**; the
library does not compute anything. They come in up to four variants that
differ in the option price they start from:

- `bid_computation`, `ask_computation`, `last_computation` — implied
  volatility (and greeks) backed out of the option's bid, ask or last price;
- `model_computation` — IB's model volatility and the resulting model price
  (`option_price`). This is usually the variant to use for greeks.

Each variant (`ibapi.market_data.OptionComputation`) has `implied_vol`,
`delta`, `gamma`, `vega`, `theta`, `option_price`, `pv_dividend` (present
value of expected dividends) and `underlying_price` (the price of the
underlying used). Values TWS could not compute are `null`: TWS marks them
with -1 (prices, volatility) or -2 (greeks). IB's documentation does not
describe these markers; the library follows IB's reference C++ client here.

## Live or frozen data

`Client.Options.market_data_type` selects the data for the whole connection:

- `.frozen` (default) — live data while the market is open, otherwise the
  last values from the close. Use it when you need prices outside trading hours.
- `.live` — only real-time data.

Both need a market data subscription for the instrument (for US options
OPRA). Without it the snapshot fails with `error.RequestRejected` and TWS
error 354 in the diagnostics. TWS may instead switch to delayed data
(warning 2186 or 10167, or a delayed data type; seen on a paper account
during US trading hours). The library never accepts delayed data, so this
also ends with `error.RequestRejected`: with code 2186 / 10167 and its text,
or with code 0 and a message naming the data type. TWS still sends the
whole delayed snapshot; the library reads and drops it first (within the
time limit), so delayed data never reach the notices either. Error 10090 (part of the
data not subscribed) is only a warning and does not end the snapshot.

## Time limits

TWS can take up to about 11 seconds to complete a snapshot, so the default
limit is `Client.Options.snapshot_timeout` = 15 s. A single call can use
`.{ .timeout = .fromSeconds(30) }`. When the limit expires the request is
cancelled in TWS.

## Several contracts

Snapshots can run concurrently on one connection:

```zig
var a = io.async(ibapi.Client.snapshot, .{ client, Query.stock("AAPL", "USD"), .{} });
var b = io.async(ibapi.Client.snapshot, .{ client, Query.stock("MSFT", "USD"), .{} });
const qa = try a.await(io);
const qb = try b.await(io);
```

TWS limits the number of simultaneous market data requests (usually 100).

## Example program

`examples/quote.zig`:

```sh
./zig-out/bin/quote AAPL
./zig-out/bin/quote AAPL 20261218 190 C
```
