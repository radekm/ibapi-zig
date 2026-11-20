# Příkazy (jen čtení)

[English version](../en/orders.md)

ibapi-zig zatím příkazy umí jen **číst**. Nemůže je zadávat, měnit ani
rušit; zprávy, které by to dělaly, v knihovně vůbec nejsou.

## Otevřené příkazy

```zig
var list = try client.openOrders(gpa, .{});
defer list.deinit();
for (list.items) |*o| {
    std.debug.print("{s} {?d} {s} {t}, vyplněno {?d} z {?d}\n", .{
        o.contract.symbol orelse "?",
        o.totalQuantity(),
        o.orderType() orelse "?",
        o.statusKind(),
        o.filledQuantity(),
        o.totalQuantity(),
    });
}
```

`openOrders` vrací příkazy všech API klientů a příkazy zadané v TWS
(požadavek TWS `ReqAllOpenOrders`) a v TWS nic nemění.

Knihovna záměrně nenabízí `ReqOpenOrders` (jen příkazy tohoto client id):
pro client id 0 by TWS ruční příkazy z TWS *přivázal* k API klientovi, tj.
přidělil jim API order id. Jen vlastní příkazy získáte filtrováním podle
`clientId()`.

## Co příkaz obsahuje

TWS popisuje každý příkaz dvěma zprávami: `OpenOrder` (kontrakt, parametry
příkazu, stav) a `OrderStatus` (vyplnění). Knihovna je spojí do jednoho
`ibapi.orders.Order`; když TWS pošle k jednomu příkazu víc aktualizací
stavu, zůstane poslední.

| Pole / metoda | Význam |
| --- | --- |
| `order_id` | order id od API klienta, který příkaz zadal (0 pro příkazy z TWS) |
| `permId()` | trvalé id přidělené TWS, jedinečné napříč klienty i sezeními |
| `clientId()`, `parentId()`, `account()` | zadávající klient, nadřazený příkaz (bracket), účet |
| `action()` | `.buy`, `.sell` nebo `.sell_short` |
| `totalQuantity()`, `filledQuantity()`, `remainingQuantity()` | množství |
| `orderType()`, `timeInForce()` | např. `LMT`, `DAY` |
| `limitPrice()`, `auxPrice()` | limitní cena; stop cena nebo trailing částka |
| `avgFillPrice()` | průměrná cena dosavadních vyplnění |
| `statusKind()` | `ibapi.orders.Status`, např. `.submitted`, `.filled`; `isActive()` |
| `contract` | `ibapi.proto.Contract` |
| `order`, `state` | `ibapi.proto.Order`, `ibapi.proto.OrderState` — vše, co TWS poslal |
| `status` | poslední `ibapi.proto.OrderStatus`, nebo `null` |

Hodnoty, které TWS neposlal, jsou `null`.

## Dokončené příkazy

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

Vrací příkazy, které byly vyplněny, zrušeny nebo odmítnuty (pokud je TWS
ještě drží, obvykle za aktuální den). Jejich `status` je `null`; konečný stav
je ve `state.status`, `state.completedTime` a `state.completedStatus`.
Celkové množství dokončených příkazů posílá TWS jako `0` (pozorováno
u vyplněného příkazu na paper účtu); provedené množství je ve
`filledQuantity()`.
`.api_only = true` vynechá příkazy zadané v TWS.

## Aktualizace po požadavku

Po požadavku na otevřené příkazy TWS dál sám posílá jejich změny (zprávy
`OpenOrder` a `OrderStatus`). Ty se doručují jako notices; čtou se přes
`client.nextNotice(timeout)`:

```zig
var n = (try client.nextNotice(.{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } })) orelse return;
defer n.deinit(gpa);
switch (n) {
    .order_status => |s| std.debug.print("příkaz {?d}: {s}\n", .{ s.orderId, s.status orelse "" }),
    else => {},
}
```

Aktualizace, které dorazí, zatímco běží `openOrders`, se stanou součástí
jeho výsledku.

## Časové limity

Oba požadavky používají `Client.Options.request_timeout` (10 s), případně
`.timeout` jednotlivého volání. TWS je neumí zrušit; odpověď, která dorazí
po vypršení limitu, se doručí jako notices.

## Ukázkový program

`examples/orders.zig`:

```sh
./zig-out/bin/orders             # všechny otevřené příkazy
./zig-out/bin/orders completed   # dokončené příkazy
```
