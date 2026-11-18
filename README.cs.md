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

## Licence

ibapi-zig je pod [licencí zlib](LICENSE).

Soubory `.proto` z TWS API, které dodáte, jsou © Interactive Brokers LLC
pod licencí GPL v3 nebo novější. Na kód z nich vygenerovaný a programy,
které ho obsahují, se tato licence může vztahovat — ověřte si to pro svůj
případ použití.
