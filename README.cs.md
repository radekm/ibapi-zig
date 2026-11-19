# ibapi-zig

[English version](README.md)

Knihovna v jazyce Zig pro Interactive Brokers: komunikuje s Trader
Workstation (TWS) nebo IB Gateway pomocí **protobuf** varianty TWS API.

> **Stav:** raná fáze vývoje. Prvním cílem je přístup jen pro čtení:
> vyhledání kontraktů, ceny akcií a opcí a seznam otevřených příkazů.
> Zadávání, úpravy a rušení příkazů přijdou později.
> Viz [PLAN.md](PLAN.md).

## Požadavky

- Zig **0.17.1**
- TWS nebo IB Gateway **10.40 nebo novější** (server version ≥ 213) se zapnutým API

## Sestavení

```sh
zig build test               # unit testy a testy proti falešnému TWS
zig build examples           # ukázkové programy do zig-out/bin
zig build docs               # referenční dokumentace API do zig-out/docs
zig build test-integration   # volitelné, potřebuje paper TWS / IB Gateway (viz níže)
```

### Integrační test

`zig build test-integration` se připojí k běžícímu TWS / IB Gateway
(`IBAPI_HOST`, `IBAPI_PORT`, `IBAPI_CLIENT_ID`; výchozí 127.0.0.1, 7497, 17),
posílá jen požadavky, které nic nemění, a vypíše výsledek každého kroku.
Odmítne běžet, pokud id některého účtu přihlášení nezačíná na `D` jako
u paper účtů (IB tento prefix nedokumentuje, takže jde jen o pojistku). Kroky, které potřebují předplatné tržních dat, hlásí jako přeskočené.

## Protobuf zprávy

Typy zpráv TWS API v Zigu jsou vygenerované ze souborů `.proto` z
**TWS API 10.52.01** pomocí [zig-protobuf](https://github.com/Arwalk/zig-protobuf)
a uložené v `src/proto/protobuf.pb.zig`. Samotné soubory `.proto` v
repozitáři nejsou.

Pro jinou verzi TWS API ji stáhněte z <https://interactivebrokers.github.io/>,
rozbalte a spusťte:

```sh
zig build gen-proto -Dproto-dir=/cesta/k/twsapi/source/proto
```

Ve výchozím stavu si zig-protobuf stáhne `protoc` 36.2; vlastní `protoc`
nastavíte přes `-Dprotoc=/cesta/k/protoc`.

## Použití jako závislost

```sh
zig fetch --save "git+https://github.com/radekm/ibapi-zig#main"
```

V `build.zig`:

```zig
const ibapi_dep = b.dependency("ibapi_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ibapi", ibapi_dep.module("ibapi"));
```

## Použití

```zig
const std = @import("std");
const ibapi = @import("ibapi");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const client = try ibapi.Client.connect(io, gpa, .{ .port = 7497, .client_id = 1 });
    defer client.close();

    std.log.info("server version {d}, accounts {s}", .{ client.serverVersion(), client.managedAccounts() });

    var details = try client.contractDetails(gpa, ibapi.contract.Query.stock("AAPL", "USD"), .{});
    defer details.deinit();
    if (details.items.len == 0) return error.NotFound;
    const aapl = details.items[0].contract orelse return error.NotFound;
    const con_id = aapl.conId orelse return error.NotFound;

    const quote = try client.snapshot(ibapi.contract.Query.byConId(con_id, "SMART"), .{});
    std.log.info("AAPL bid {?d} ask {?d}", .{ quote.bid, quote.ask });

    var orders = try client.openOrders(gpa, .{});
    defer orders.deinit();
    std.log.info("{d} open orders", .{orders.items.len});
}
```

Všechny metody klienta a zprávy, které si vyměňují s TWS, jsou v přehledu
[Metody klienta a jejich zprávy](docs/cs/api.md).

Každá operace má timeout: `connect_timeout`, `request_timeout`,
`snapshot_timeout` a `write_timeout` v `ibapi.Client.Options`
(výchozí 10 s, 10 s, 15 s a 5 s) a
`nextNotice` ho dostává explicitně. Vypršení se hlásí jako `error.Timeout`.
Za sekundu se pošle nejvýš `max_messages_per_second` (50) zpráv.

Klient se znovu nepřipojuje: po ztrátě spojení požadavky končí s
`error.ConnectionClosed` / `error.ConnectionLost`; zavřete ho a připojte se znovu.

Požadavky mohou na jednom spojení běžet souběžně, např.
`var f = io.async(ibapi.Client.currentTime, .{client});` a později `try f.await(io)`.
Zprávy, které nepatří k žádnému požadavku (informativní chyby apod.), se čtou
přes `client.nextNotice(timeout)`.

## Návody

- [Metody klienta a jejich zprávy](docs/cs/api.md)
- [Vyhledávání kontraktů a opčních řetězců](docs/cs/contracts.md)
- [Ceny akcií a opcí](docs/cs/prices.md)
- [Příkazy (jen čtení)](docs/cs/orders.md)
- [Síťový protokol](docs/cs/protocol.md)

## Příklady

Příklady čtou nastavení spojení ze souboru `Config.zon` v aktuálním
pracovním adresáři (git ho ignoruje):

```sh
zig build examples
cp examples/Config.example.zon Config.zon   # pak upravte host, port, client_id
./zig-out/bin/connect
./zig-out/bin/contracts details AAPL
./zig-out/bin/option_chain AAPL 45
./zig-out/bin/quote AAPL 20261218 190 C
./zig-out/bin/orders
```

## Licence

ibapi-zig je pod [licencí zlib](LICENSE).
Definice zpráv v `src/proto` jsou vygenerované ze souborů `.proto` TWS API
od Interactive Brokers LLC.
