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
- [x] TWS "not computed" sentinels (-1/-2) mapped to null
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
- [ ] Pacing / rate limit (max ~50 msgs/s) in the writer
- [ ] Reconnect strategy (documented, opt-in)
- [ ] API docs (`zig build docs`), README usage guide
- [ ] Opt-in integration tests against a paper account

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
  waits would end it early with a partial list. Check against real TWS.
- Order updates that arrive while `openOrders` waits are consumed by it (and
  lost if it times out) instead of going to the notices.
- `ErrorMessage.id` is an order id for order-related errors; such an error
  could be misrouted to a pending request with the same request id. Not an
  issue while the library places no orders; revisit before the order phase.
- Warning codes: only 2100–2199 are treated as non-terminal for requests so far;
  extend in M4 (e.g. 10167 delayed market data) when market data needs it.
