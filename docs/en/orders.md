# Orders (read-only)

[Česká verze](../cs/orders.md)

ibapi-zig can currently only **read** orders. It cannot place, modify or
cancel them; the messages for that are not even part of the library.

## Open orders

```zig
var list = try client.openOrders(gpa, .all_clients, .{});
defer list.deinit();
for (list.items) |*o| {
    std.debug.print("{s} {?d} {s} {t}, filled {?d} of {?d}\n", .{
        o.contract.symbol orelse "?",
        o.totalQuantity(),
        o.orderType() orelse "?",
        o.statusKind(),
        o.filledQuantity(),
        o.totalQuantity(),
    });
}
```

The second argument selects which orders TWS returns:

| Scope | TWS request | Orders |
| --- | --- | --- |
| `.all_clients` | `ReqAllOpenOrders` | orders of all API clients and orders entered in TWS |
| `.this_client` | `ReqOpenOrders` | only orders placed by this client id |

`.all_clients` changes nothing in TWS. With `.this_client` and **client id 0**,
TWS additionally *binds* orders entered manually in TWS to this API client,
i.e. assigns them API order ids. Use `.all_clients` if you only want to look.

## What an order contains

TWS describes each order with two messages: `OpenOrder` (contract, order
parameters, state) and `OrderStatus` (fills). The library merges them into
one `ibapi.orders.Order`; when TWS sends several status updates of one
order, the latest one is kept.

| Field / method | Meaning |
| --- | --- |
| `order_id` | order id given by the placing API client (0 for orders from TWS) |
| `permId()` | permanent id assigned by TWS, unique across clients and sessions |
| `clientId()`, `parentId()`, `account()` | placing client, parent (bracket) order, account |
| `action()` | `.buy`, `.sell` or `.sell_short` |
| `totalQuantity()`, `filledQuantity()`, `remainingQuantity()` | quantities |
| `orderType()`, `timeInForce()` | e.g. `LMT`, `DAY` |
| `limitPrice()`, `auxPrice()` | limit price; stop price or trailing amount |
| `avgFillPrice()` | average price of fills so far |
| `statusKind()` | `ibapi.orders.Status`, e.g. `.submitted`, `.filled`; `isActive()` |
| `contract` | `ibapi.proto.Contract` |
| `order`, `state` | `ibapi.proto.Order`, `ibapi.proto.OrderState` — everything TWS sent |
| `status` | the latest `ibapi.proto.OrderStatus`, or `null` |

Values TWS did not send are `null`.

## Completed orders

```zig
var done = try client.completedOrders(gpa, .{ .api_only = false });
defer done.deinit();
for (done.items) |*o| {
    std.debug.print("{s} {t} {s}\n", .{
        o.contract.symbol orelse "?",
        o.statusKind(),
        o.state.completedTime orelse "",
    });
}
```

Returns orders that were filled, cancelled or rejected (as far as TWS keeps
them, usually the current day). Their `status` is `null`; the final state is
in `state.status`, `state.completedTime` and `state.completedStatus`.
`.api_only = true` leaves out orders entered in TWS.

## Updates after the request

After an open orders request TWS keeps sending changes of the orders
(`OpenOrder` and `OrderStatus` messages) without being asked. They are
delivered as notices; read them with `client.nextNotice(timeout)`:

```zig
var n = (try client.nextNotice(.{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } })) orelse return;
defer n.deinit(gpa);
switch (n) {
    .order_status => |s| std.debug.print("order {?d}: {s}\n", .{ s.orderId, s.status orelse "" }),
    else => {},
}
```

Updates that arrive while `openOrders` is running become part of its result.

## Time limits

Both requests use `Client.Options.request_timeout` (10 s), or `.timeout` of
the single call. TWS has no way to cancel them; an answer that arrives after
the timeout is delivered as notices.

## Example program

`examples/orders.zig`:

```sh
./zig-out/bin/orders             # all open orders
./zig-out/bin/orders mine        # orders of this client id
./zig-out/bin/orders completed   # completed orders
```
