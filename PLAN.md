# PLAN.md — ibapi-zig

Goal: a Zig library for trading on Interactive Brokers through TWS or
IB Gateway using the protobuf TWS API. Phase 1 is read-only; order
management comes later.

## Decisions

| Topic | Decision |
| --- | --- |
| Language | Zig 0.17.1 |
| Protocol | Protobuf only, server version ≥ 213 (TWS / IB Gateway 10.40+) |
| License | zlib |
| `.proto` files | Not in the repo; reference version TWS API 10.52.01 |
| Code generation | `zig build gen-proto -Dproto-dir=…` (protoc + zig-protobuf); output `src/proto/protobuf.pb.zig` is committed |
| Documentation | English and Czech in separate files (`README.md` / `README.cs.md`, `docs/en` / `docs/cs`) |
| Branches | `main` only |
| Concurrency | Asynchronous API on top of `std.Io` (futures, queues, groups) |
| Dependencies | zig-protobuf only |
| Special values | Interpret a value as "missing" or "special" only when IB's official documentation says so (e.g. tick price -1). Exceptions, each documented in the code: option computation -1/-2 (IB's reference C++ client does it), ids of 0 when merging orders (needed to keep distinct orders apart). No DBL_MAX handling. Absent protobuf fields are null. |

## Architecture

```
application
    │  io: std.Io, allocator
    ▼
ibapi.Client ───────────────────────────────────────────────┐
  • connect(): TCP via std.Io.net, handshake, start API      │
  • reader task (io.concurrent): read frame → decode →       │
    route by request id / order id                           │
  • per-request routing table: reqId → Io.Queue / result     │
  • notice queue: unsolicited messages and errors            │
  • writer: frames serialised under an Io.Mutex              │
  • request ids allocated atomically                         │
    ▼                                                        │
ibapi.wire: length-prefixed frames, msg id + protobuf body ◄─┘
    ▼
ibapi.proto: types generated from proto/*.proto
```

### Wire protocol (details in `docs/en/protocol.md`)

1. Client sends `API\0`, then a length-prefixed version range string
   `v100..226`.
2. Server replies with its server version and connection time;
   reject if `< 213`.
3. Client sends StartApi (client id, optional capabilities).
4. Server sends `nextValidId` and `managedAccounts` — the client is ready.
5. Afterwards every frame is: 4-byte big-endian length, 4-byte big-endian
   message id (protobuf ids are offset by 200), protobuf-encoded payload.

### Public API sketch

```zig
var client = try ibapi.Client.connect(io, gpa, .{ .host = "127.0.0.1", .port = 7497, .client_id = 1 });
defer client.close();

// Contracts for a symbol (all results collected until ContractDataEnd).
var details = try client.contractDetails(gpa, ibapi.contract.Query.stock("AAPL", "USD"), .{});
defer details.deinit();

// Option chain parameters (expirations, strikes, exchanges).
var chain = try client.optionChainParams(gpa, .{ .symbol = "AAPL", .con_id = 265598 }, .{});

// Price snapshot (bid/ask/last/close, greeks for options).
const quote = try client.snapshot(ibapi.contract.Query.byConId(265598, "SMART"), .{});

// Open orders of the account(s), merged with their latest status.
var orders = try client.openOrders(gpa, .{});
defer orders.deinit();
```

Asynchronous use: any call can be started with `io.async(Client.contractDetails, .{...})`
and awaited later, so several requests run concurrently on one connection.

## Milestones

### M0 — Project skeleton
- [x] AGENTS.md, PLAN.md
- [x] `build.zig` / `build.zig.zon` with zig-protobuf, `gen-proto` step, committed generated code, `ibapi` module
- [x] `zig build test` with a protobuf round-trip test of a generated message
- [x] README in English and Czech, zlib LICENSE
- [x] GitHub Actions: `zig fmt --check` and `zig build test`

### M1 — Transport and connection
- [x] `wire`: frame reader/writer over `std.Io.Reader` / `std.Io.Writer` (+ unit tests)
- [x] Handshake, server version check, StartApi
- [x] Reader task, request id allocator, routing table, notice queue
- [x] `ErrorMessage` routed to the request by `id`, otherwise to notices
- [ ] Typed classification of error codes (informational 2104/2106/2158 … vs. failures);
      done per request type in M2–M4 when we know which codes matter
- [x] `nextValidId`, `managedAccounts` (from the handshake), `currentTime()`
- [x] Fake TWS server for tests (scripted, over a loopback socket)
- [x] Clean shutdown: cancel the reader task, close socket, fail pending requests
- [x] Timeouts everywhere: `connect_timeout` (TCP + handshake), `request_timeout`
      (whole request), `write_timeout` (per message, a timed-out write closes the
      connection), explicit timeout for `nextNotice`

### M2 — Contract details
- [x] `contractDetails()` — request, collect `ContractData` (+ bond variant) until
      `ContractDataEnd`; TWS errors → `error.RequestRejected` + `Diagnostics`;
      cancel on timeout (server ≥ 215)
- [x] Ergonomic contract builders: `contract.Query` with stock, option, future, index, forex, byConId
- [x] `searchSymbols()` (MatchingSymbols)
- [x] Per-request options: `timeout`, `diagnostics`
- [x] Example `examples/contracts.zig`, guide `docs/{en,cs}/contracts.md`

### M3 — Option chains
- [x] `optionChainParams()` (SecDefOptParams: exchanges, expirations, strikes, multiplier)
- [x] No special helper for filtering by expiration (owner's decision): strikes of one
      expiration come from `contractDetails`; documented in `docs/{en,cs}/contracts.md`
- [x] Example `examples/option_chain.zig` (expirations within N days + strikes of the nearest)

### M4 — Prices (snapshots only)
Owner's decisions: only snapshots, **never streaming subscriptions**; only
`live` and `frozen` market data (no delayed data).
- [x] `Options.market_data_type` (`.live` / `.frozen`, default `.frozen`), sent after connecting
- [x] `snapshot()` — snapshot request, ticks aggregated into `market_data.Quote` until
      `TickSnapshotEnd`: bid/ask/last + sizes, last time, open/high/low/close, volume,
      option model computations (bid/ask/last/model: IV, greeks, PV dividend, underlying price)
- [x] TWS "not computed" sentinels (-1/-2) mapped to null (follows IB's reference client, not documented)
- [x] Errors: 354 → `error.RequestRejected`; 10090/10167 are warnings; cancel on timeout;
      `Options.snapshot_timeout` (15 s, TWS needs up to ~11 s)
- [x] Example `examples/quote.zig`, guide `docs/{en,cs}/prices.md`

### M5 — Open orders (read-only)
- [x] Routing by a set of message kinds (`Client.Key.kinds`); requests routed by
      kind are registered and sent under one lock (`registerKindsAndSend`), so
      their FIFO order matches the order the server receives them
- [x] `openOrders(gpa, opts)` — ReqAllOpenOrders, collect `OpenOrder` + `OrderStatus`
      until `OpenOrderEnd`. Owner's decision: no ReqOpenOrders (for client id 0 it
      binds manual TWS orders); it is not even in `wire.OutMsg`
- [x] Merge open order and its latest status into one `orders.Order` view
      (matched by perm id, else by order id + client id), typed helpers
      (`Status`, `Action`, quantities, prices)
- [x] `completedOrders(gpa, .{ .api_only })` (CompletedOrder until CompletedOrdersEnd)
- [x] Unsolicited order updates outside a request go to notices
- [x] Example `examples/orders.zig`, guide `docs/{en,cs}/orders.md`

### M6 — Hardening and docs
Owner's decision: **no reconnect**. A lost connection fails all requests; the
application closes the client and connects again (documented).
- [x] Pacing in `Client.send`: at most `Options.max_messages_per_second` (50) in
      any one-second window (`Pacer`); a wait longer than `write_timeout` fails
      with `error.Timeout` before anything is written
      Owner's decision: pacing stays client-side only; the `+PACEAPI` connect
      option (TWS-side pacing) is not sent. TWS may still reject or pace by
      its own API setting; the real limit is market data lines / 2 per second
      (50 by default), hence the option is configurable
- [x] API docs (`zig build docs`), README usage guide
- [x] `docs/{en,cs}/api.md`: every client method with the protobuf messages it
      sends and receives, error and notice routing, limits
- [x] Opt-in integration test `zig build test-integration` (`tests/integration.zig`,
      compiled by `zig build test`): connection from `Config.zon` in the current
      directory (shared with the examples via the `common` module), refuses
      non-paper logins (account ids not starting with `D`), read-only steps,
      lists what TWS sends unasked after connecting
- [x] Review for undefined behaviour and liveness (see the commit "Fix issues
      found in the review"): unnamed enum values printed with `@tagName`,
      `.?` on server data, duplicate request ids, reader blocked without a
      timeout on a full request buffer, requests kept busy past their deadline,
      cancel messages not sent from canceled tasks, large stack buffers
- [x] Handshake waits for both `NextValidId` and `ManagedAccounts`: the
      owner's paper TWS (server version 226) sent `NextValidId` first, the
      accounts went to the notices and the integration test failed with
      `NoManagedAccounts`
- [ ] Run the integration test against a real paper TWS / IB Gateway (owner) and
      resolve the open questions below

### M7 — Historical bars (OHLC)
Owner's decisions: only **1 min** and **1 day** bars (the application
aggregates larger bars itself); **never `keepUpToDate`** (it is a
subscription), so `HistoricalDataUpdate` is not decoded; no
`reqHeadTimestamp` (it falls under the strict small-bar pacing rules and must
be cancelled; not needed for the intended use: minutes of one day, days of a
few months). Typical requests are small, so there is no pause between chunks.
- [x] `wire`/`Incoming`: `HistoricalDataRequest` (20), `CancelHistoricalData` (25),
      `HistoricalData` (17), `HistoricalDataEnd` (108)
- [x] `history`: `MinuteBar` (`time: Io.Timestamp`, start of the bar, UTC) and
      `DailyBar` (`day: std.time.epoch.EpochDay`, the exchange's trading day);
      OHLC as `?f64`, volume and WAP decimal strings parsed to `?f64`
      (empty = null; no other special values), bar count `?i32`; `history.day(y, m, d)`
- [x] `minuteBars(gpa, query, .{ start, end, what_to_show, use_rth })`: bars whose
      start lies in `[start, end)`; `end = null` means now (the unfinished
      current bar may be included). Sent with `formatDate = 2` (epoch seconds)
      and `endDateTime` as UTC `YYYYMMDD-HH:mm:ss`; durations in seconds,
      at least 60 S, at most 86400 S per request; longer ranges are split and
      walked backwards from the end (next end = earliest bar received)
- [x] `dailyBars(gpa, query, .{ first, last, … })`: bars of days `first..last`
      (both inclusive, `last = null` means today); one request, `N D` up to
      365 days, else `N Y`; dates `yyyyMMdd`
- [x] `what_to_show`: trades (default), midpoint, bid, ask, bid_ask (OHLC has a
      special meaning, documented), adjusted_last, historical_volatility,
      option_implied_volatility; `use_rth` default true
- [x] Error 162 whose text says the query returned no data = no bars (empty
      chunk); any other error → `error.RequestRejected`
- [x] At most `Options.max_historical_requests` (50, the IB limit) historical
      requests open at once; waiting for a slot is bounded by the request's deadline
- [x] `Options.historical_timeout` (60 s) per request sent to TWS (one chunk);
      `CancelHistoricalData` on timeout or cancelation
- [x] Example `examples/bars.zig`, guide `docs/{en,cs}/history.md`, `api.md`
- [x] Integration test must pass on a paper account **without paid market
      data** (owner's decision): AAPL bars are required (TWS returns them
      ~15 min delayed with warning 2188 without a subscription); the AAPL
      snapshot (354 not subscribed) and the EUR.USD bars (162 "No market data
      permissions for IDEALPRO CASH": free forex data needs forex trading
      permissions) are skipped when rejected. No EUR.USD snapshot: without
      permissions TWS did not answer it at all (timeout)
- [ ] Check against a real paper TWS: boundary bars of `endDateTime`, text of
      the "no data" error, whether `D` durations count calendar or trading days

### Later phases (not started)
- Account: positions, account summary, PnL, executions
- Orders: place, modify, cancel (requires explicit go-ahead; paper first)

## Resolved questions
- Handshake and framing were verified against the reference C++ client of
  TWS API 10.52.01 (used only as a reference, nothing copied); see
  `docs/en/protocol.md`. The server hello is still text, StartApi is
  protobuf from server version 213, and with 213+ every request needed
  for M1–M5 is protobuf.

## Open questions
- Behaviour against a real TWS / IB Gateway still has to be checked with a
  paper account (integration tests, M6).
- `std.Io.Threaded` in Zig 0.17.1 does not implement TCP connect timeouts
  (it panics), so `connect` races the connection attempt against a timer.
  Replace with `ConnectOptions.timeout` once Zig implements it.
- Does TWS send open orders (and `OpenOrderEnd`?) on its own right after a
  client connects? An unsolicited `OpenOrderEnd` arriving while `openOrders`
  waits would end it early with a partial list. First paper run (server 226,
  no open orders): only 2104/2106/2158 farm notices arrived; recheck with
  open orders.
- TWS 10.52 servers (226) send `CompletedOrder` fields 31, 36 and 37 that
  the 10.52.01 `.proto` files do not define; zig-protobuf skips them (debug
  log). Regenerate from newer `.proto` files when IB publishes them.
- A snapshot without market data permissions (EUR.USD, no forex
  permissions) got no answer at all and ended with `error.Timeout`, not a
  rejection. Check whether TWS sends something we do not route.
- Order updates that arrive while `openOrders` waits are consumed by it (and
  lost if it times out) instead of going to the notices.
- `ErrorMessage.id` is an order id for order-related errors; such an error
  could be misrouted to a pending request with the same request id. Not an
  issue while the library places no orders; revisit before the order phase.
- How does TWS encode unset decimal quantities (`Order.totalQuantity`,
  `OrderStatus.filled`, tick sizes) in protobuf: empty/absent, or a huge
  sentinel number? `parseDecimal` treats only empty/absent as unset.
- Warning codes: only 2100–2199 are treated as non-terminal for requests so far;
  extend in M4 (e.g. 10167 delayed market data) when market data needs it.
