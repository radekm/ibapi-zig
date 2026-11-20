# Historical bars (OHLC)

[Česká verze](../cs/history.md)

ibapi-zig downloads **1-minute** and **1-day** bars. Larger bars (5 minutes,
an hour, a week) are easy to aggregate from them. Every request is one-off:
the library never asks TWS to keep the bars up to date (`keepUpToDate`),
because that would be a subscription.

```zig
const history = ibapi.history;
const Query = ibapi.contract.Query;

// 1-minute bars of the last hour.
const now = std.Io.Timestamp.now(io, .real);
var minutes = try client.minuteBars(gpa, Query.stock("AAPL", "USD"), .{
    .start = now.subDuration(.fromSeconds(3600)),
}, .{});
defer minutes.deinit();
for (minutes.items) |b| {
    std.debug.print("{d} {?d} {?d} {?d} {?d} {?d}\n", .{ history.floorSeconds(b.time), b.open, b.high, b.low, b.close, b.volume });
}

// Daily bars of January 2025.
var days = try client.dailyBars(gpa, Query.stock("AAPL", "USD"), .{
    .first = try history.day(2025, 1, 2),
    .last = try history.day(2025, 1, 31),
}, .{});
defer days.deinit();
```

Without a market data subscription TWS may still return bars, but only up
to about 15 minutes ago, with warning 2188 ("Up-to-the-second historical data
requires additional subscription"; seen on a paper account for US stocks);
the warning is only logged. Where data is not available at all, TWS rejects
the request (`error.RequestRejected`, e.g. 162 "No market data permissions").
Forex data is free, but only for accounts with forex trading permissions.
Forex has no trades, so use `.what_to_show = .midpoint` (or `.bid`, `.ask`)
for currency pairs, e.g. `Query.forex("EUR", "USD")`.

## Which bars are returned

| Method | Range | Bar time |
| --- | --- | --- |
| `minuteBars` | bars whose **start** lies in `[start, end)`; `end = null` means now | `time: std.Io.Timestamp` — start of the bar, an instant (UTC) |
| `dailyBars` | trading days `first..last`, **both inclusive**; `last = null` means today | `day: history.Day` (`std.time.epoch.EpochDay`) — the exchange's trading day, without time or time zone |

Examples for `minuteBars`:

- `start = 17:23:15`, `end = 17:30:00` → bars 17:24 … 17:29. The bar 17:23
  started before `start`, so it is not included; the bar 17:29 covers
  17:29–17:30.
- To include the bar that contains `start`, round `start` down to a whole
  minute yourself.
- With `end = null` the current, still unfinished bar may be included (its
  values still change). The same holds for today's bar in `dailyBars`.

`history.day(year, month, day)` creates a `Day`;
`d.calculateYearDay().calculateMonthDay()` converts it back to a date.

The result is sorted from the oldest bar and has no duplicates. Days and
minutes without trading (nights, weekends, holidays, data older than IB
keeps) simply have no bars; an empty range is not an error.

## Bar fields

`history.MinuteBar` and `history.DailyBar`:

| Field | Meaning |
| --- | --- |
| `open`, `high`, `low`, `close` | prices (see `what_to_show`) |
| `volume` | traded volume; only for `.trades` |
| `wap` | volume-weighted average price; only for `.trades` |
| `count` | number of trades; only for `.trades` |

Every field is optional (`null` when TWS did not send it). IB documents no
special values for bars, so the library does not interpret any.

## What the bars are built from (`what_to_show`)

| Value | Bars |
| --- | --- |
| `.trades` (default) | trades; the only kind with volume, WAP and trade count |
| `.midpoint` | midpoint of bid and ask |
| `.bid`, `.ask` | bid or ask prices |
| `.bid_ask` | **special meaning**: `open` = time-average bid, `high` = highest ask, `low` = lowest bid, `close` = time-average ask. IB counts these requests twice towards its limits. |
| `.adjusted_last` | trades adjusted for splits and dividends; `end` / `last` must be null (IB requires the request to end now), and a `minuteBars` range at most one day |
| `.historical_volatility` | historical volatility |
| `.option_implied_volatility` | implied volatility of the options |

`use_rth` (default `true`) limits the bars to regular trading hours.

## Requests sent to TWS and limits

- `minuteBars` asks for at most one day (86 400 s) per request. A longer
  range is split into requests of one day each, sent one after another from
  the end and overlapping by one bar. `endDateTime` is sent in UTC
  (`YYYYMMDD-HH:mm:ss`) and bar times as Unix seconds, so the time zone set
  in TWS does not matter.
- `dailyBars` is one request (`N D` up to a year, `N Y` beyond).
- `opts.timeout` (default `Options.historical_timeout`, 60 s) applies to each
  request sent to TWS; TWS may slow down historical requests.
- At most `Options.max_historical_requests` (50, IB's limit) historical
  requests are open at the same time; further ones wait for a free slot,
  within their timeout.
- On timeout or cancelation the request is canceled at TWS
  (`CancelHistoricalData`).
- Error 162 whose text says the query "returned no data" means an empty
  result. Any other error (e.g. 162 pacing violation) ends the call with
  `error.RequestRejected` and the details in `opts.diagnostics`.
- IB's strict pacing rules (60 requests in 10 minutes, identical requests
  within 15 s) apply to bars of 30 seconds or less, which the library does
  not offer. For 1-minute and larger bars IB only slows down clients that
  ask for too much; there is no pause between requests.

The example `zig-out/bin/bars AAPL minutes 2` / `bars AAPL days 30` prints
bars of a stock.
