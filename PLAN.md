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
| `.proto` files | Not in the repo (GPL v3); supplied via `-Dproto-dir`, reference version TWS API 10.52.01 |
| Code generation | protoc + zig-protobuf generator at build time, output in the build cache |
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
const details = try client.contractDetails(gpa, .{ .symbol = "AAPL", .sec_type = .stk, .currency = "USD" });
defer details.deinit();

// Option chain parameters (expirations, strikes, exchanges).
const chain = try client.optionChainParams(gpa, .{ .underlying_symbol = "AAPL", .underlying_con_id = 265598, .sec_type = .stk });

// Price snapshot (bid/ask/last/close, greeks for options).
const quote = try client.snapshot(gpa, .{ .con_id = 265598, .exchange = "SMART" });

// Streaming quotes — returns a Subscription with `next()` and `cancel()`.
var sub = try client.subscribeMarketData(.{ .con_id = 265598, .exchange = "SMART" }, .{});
defer sub.cancel();
while (try sub.next()) |tick| { ... }

// Open orders of the account(s).
const orders = try client.openOrders(gpa, .all_clients);
```

Asynchronous use: any call can be started with `io.async(Client.contractDetails, .{...})`
and awaited later, so several requests run concurrently on one connection.

## Milestones

### M0 — Project skeleton
- [x] AGENTS.md, PLAN.md
- [x] `build.zig` / `build.zig.zon` with zig-protobuf, `-Dproto-dir`, codegen into the cache, `ibapi` module
- [x] `zig build test` with a protobuf round-trip test of a generated message
- [x] README in English and Czech, zlib LICENSE
- [x] GitHub Actions: `zig fmt --check` and build script check
      (tests cannot run in CI because the `.proto` files are not public)

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

### M2 — Contract details
- [ ] `contractDetails()` — request, collect `ContractData` until `ContractDataEnd`
- [ ] Ergonomic contract builders: stock, option, future, index, forex
- [ ] `matchingSymbols()` (symbol search) — optional, if cheap
- [ ] Example `examples/contracts.zig`

### M3 — Option chains
- [ ] `optionChainParams()` (SecDefOptParams: exchanges, expirations, strikes, multiplier)
- [ ] Helper: list option contracts for an expiration via contract details
- [ ] Example `examples/option_chain.zig`

### M4 — Prices
- [ ] `setMarketDataType()` (live / frozen / delayed / delayed-frozen)
- [ ] `subscribeMarketData()` — tick price, tick size, tick string, tick generic,
      option computation (IV, greeks, underlying price); `cancel()`
- [ ] `snapshot()` — snapshot request, aggregates ticks until `TickSnapshotEnd`
- [ ] Market data errors (no subscription → 354/10167 etc.) mapped to typed errors
- [ ] Example `examples/quote.zig` for a stock and an option

### M5 — Open orders (read-only)
- [ ] `openOrders()` — ReqOpenOrders / ReqAllOpenOrders, collect `OpenOrder`
      + `OrderStatus` until `OpenOrderEnd`
- [ ] Merge open order and its latest status into one `Order` view
- [ ] Optionally `completedOrders()`
- [ ] Example `examples/orders.zig`

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
- `connect` has no timeout yet; a caller can cancel it via `io.async` +
  `Future.cancel`. Decide whether a built-in timeout option is wanted.
