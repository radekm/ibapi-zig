# Client methods and their messages

[Česká verze](../cs/api.md)

Which protobuf messages (`ibapi.proto`) each method of `ibapi.Client` sends to
TWS and which it receives. The number in parentheses is the message id; on the
wire protobuf messages carry the id + 200 (see [protocol.md](protocol.md)).
Every method can also receive `ErrorMessage` (4), see
[Errors](#errors-errormessage).

The full API reference is generated from the doc comments by `zig build docs`
(open `zig-out/docs/index.html` through a local web server, e.g.
`python3 -m http.server -d zig-out/docs`).

## Connection

| Method | Sends | Receives |
| --- | --- | --- |
| `connect` | text hello `API\0` + version range; `StartApiRequest` (71); `MarketDataTypeRequest` (59) | text server hello (version, time); `ManagedAccounts` (15); `NextValidId` (9) — ends the handshake; anything else before it goes to the notices |
| `close` | — (closes the socket) | — |
| `serverVersion`, `connectionTime`, `managedAccounts`, `nextOrderId` | — (values from the handshake; `nextOrderId` is updated by every `NextValidId`) | — |
| `nextNotice` | — | any message no request waits for (see [Notices](#notices)) |

## Requests

| Method | Sends | Receives (ends with) | Routed by |
| --- | --- | --- | --- |
| `currentTime` | `CurrentTimeRequest` (49) | `CurrentTime` (49) | kind |
| `contractDetails` | `ContractDataRequest` (9); `CancelContractData` (106) on timeout, server ≥ 215 | `ContractData` (10), `ContractData` for bonds (18), **`ContractDataEnd` (52)** | `reqId` |
| `searchSymbols` | `MatchingSymbolsRequest` (81) | **`SymbolSamples` (79)** | `reqId` |
| `optionChainParams` | `SecDefOptParamsRequest` (78) | `SecDefOptParameter` (75), **`SecDefOptParameterEnd` (76)** | `reqId` |
| `snapshot` | `MarketDataRequest` (1) with `snapshot = true`; `CancelMarketData` (2) on timeout | `TickPrice` (1), `TickSize` (2), `TickString` (46), `TickGeneric` (45), `TickOptionComputation` (21), `TickReqParams` (81), `MarketDataType` (58), **`TickSnapshotEnd` (57)** | `reqId` |
| `openOrders` | `AllOpenOrdersRequest` (16) | `OpenOrder` (5), `OrderStatus` (3), **`OpenOrdersEnd` (53)** | kind |
| `completedOrders` | `CompletedOrdersRequest` (99) | `CompletedOrder` (101), **`CompletedOrdersEnd` (102)** | kind |
| `minuteBars`, `dailyBars` | `HistoricalDataRequest` (20), one per chunk (see [history.md](history.md)), never with `keepUpToDate`; `CancelHistoricalData` (25) on timeout | `HistoricalData` (17), **`HistoricalDataEnd` (108)**; error 162 "no data" = no bars | `reqId` |

*Routed by `reqId`*: the answers carry the request id, so any number of such
requests can run at the same time. *Routed by kind*: the answers carry no
request id; requests waiting for the same kind of message are answered in the
order they were sent.

## Low-level methods

For messages the library does not wrap yet:

| Method | Purpose |
| --- | --- |
| `send(id, msg)` | sends any request listed in `ibapi.wire.OutMsg` |
| `register(r, key, end, buffer, timeout)` | starts collecting messages by `reqId` (`.req_id`) or by kind (`.kinds`) into `Client.Responses`; fails with `error.RequestIdInUse` if a pending request uses the id |
| `registerKindsAndSend(…)` | `register` by kind + `send` as one step, keeping the order of requests |
| `nextRequestId()` | a fresh request id |

`wire.OutMsg` contains only read-only requests. Requests that place, modify or
cancel orders are not there, and neither is `ReqOpenOrders` (5), which binds
manual TWS orders to client id 0.

## Errors (`ErrorMessage`)

- An error whose `id` is the id of a pending request ends that request with
  `error.RequestRejected`; the code and text are in `RequestOptions.diagnostics`.
- Warnings do not end a request and are only logged: codes 2100–2199
  (connection status), 10090 and 10167 (market data).
- Errors with `id = -1` or an id no request waits for go to the notices.

## Notices

`nextNotice(timeout)` returns messages that belong to no pending request:
informational errors (e.g. 2104 "Market data farm connection is OK"),
`NextValidId`, order updates sent after `openOrders` (`OpenOrder`,
`OrderStatus`), late answers of requests that timed out, and messages the
library does not decode (`Incoming.other`). At most `notice_capacity` (256)
unread notices are kept; newer ones are dropped and counted by
`droppedNotices()`.

## Limits

- Every request has a time limit (`Options.request_timeout`, for `snapshot`
  `Options.snapshot_timeout`, for each historical data request
  `Options.historical_timeout`, or `.timeout` of the call).
- At most `Options.max_historical_requests` (default 50) historical data
  requests are open at once; further ones wait for a free slot within their
  time limit.
- The client sends at most `Options.max_messages_per_second` (default 50)
  messages per second; further messages wait. If the wait would exceed
  `Options.write_timeout`, `send` fails with `error.Timeout` without
  touching the connection.
- A request must keep reading its responses. When its buffer is full, the
  reader waits at most until the request's deadline and then drops the
  request's messages, so one stuck request cannot stop the others for longer.
  After its deadline `Responses.next` fails with `error.Timeout` even when
  messages are still queued.
- The client does not reconnect. When the connection is lost, pending and
  later requests fail with `error.ConnectionClosed` or `error.ConnectionLost`;
  close the client and connect again.
