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
- Soubory `.proto` z TWS API — vyvíjeno a testováno s **TWS API 10.52.01**

## Jak získat soubory `.proto`

Soubory `.proto` vydává Interactive Brokers pod licencí GPL v3 a v tomto
repozitáři **nejsou**. Stáhněte TWS API z <https://interactivebrokers.github.io/>
a rozbalte ho; soubory jsou v `source/proto` (nebo v `proto` samostatného
archivu s protobufem).

## Sestavení

```sh
zig build test -Dproto-dir=/cesta/k/twsapi/source/proto
```

Build spustí `protoc` s generátorem [zig-protobuf](https://github.com/Arwalk/zig-protobuf)
a vygenerovaný kód v Zigu uloží do build cache. Ve výchozím stavu si
zig-protobuf stáhne `protoc` 36.2; vlastní `protoc` nastavíte přes
`-Dprotoc=/cesta/k/protoc`.

## Použití jako závislost

```sh
zig fetch --save "git+https://github.com/radekm/ibapi-zig#main"
```

V `build.zig`:

```zig
const ibapi_dep = b.dependency("ibapi_zig", .{
    .target = target,
    .optimize = optimize,
    .@"proto-dir" = "/cesta/k/twsapi/source/proto",
});
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
    std.log.info("server time {d}", .{try client.currentTime()});
}
```

Každá operace má timeout: `connect_timeout`, `request_timeout` a
`write_timeout` v `ibapi.Client.Options` (výchozí 10 s, 10 s a 5 s) a
`nextNotice` ho dostává explicitně. Vypršení se hlásí jako `error.Timeout`.

Požadavky mohou na jednom spojení běžet souběžně, např.
`var f = io.async(ibapi.Client.currentTime, .{client});` a později `try f.await(io)`.
Zprávy, které nepatří k žádnému požadavku (informativní chyby apod.), se čtou
přes `client.nextNotice()`. Viz [popis protokolu](docs/cs/protocol.md).

## Licence

ibapi-zig je pod [licencí zlib](LICENSE).

Soubory `.proto` z TWS API, které dodáte, jsou © Interactive Brokers LLC
pod licencí GPL v3 nebo novější. Na kód z nich vygenerovaný a programy,
které ho obsahují, se tato licence může vztahovat — ověřte si to pro svůj
případ použití.
