# Vyhledávání kontraktů

[English version](../en/contracts.md)

Kontrakt (instrument) se popisuje strukturou `ibapi.contract.Query`. Pole
ponechaná na `null` se neposílají, takže jeden dotaz může odpovídat mnoha
kontraktům.

```zig
const Query = ibapi.contract.Query;

Query.stock("AAPL", "USD")                          // AAPL přes SMART
Query.option("AAPL", "USD", "20261218", 200, .call) // jedna opce
Query.option("AAPL", "USD", "20261218", null, null) // všechny opce jedné expirace
Query.future("ES", "CME", "USD", null)              // všechny futures ES
Query.index("SPX", "CBOE", "USD")
Query.forex("EUR", "USD")                            // EUR.USD na IDEALPRO
Query.byConId(265598, "SMART")                       // podle IB contract id
```

Ostatní pole lze nastavit přímo, např.
`.{ .sec_id_type = "ISIN", .sec_id = "US0378331005", .sec_type = .stock }`.

## Detaily kontraktů

```zig
var list = try client.contractDetails(gpa, Query.stock("AAPL", "USD"), .{});
defer list.deinit();
for (list.items) |item| {
    const c = item.contract.?;          // ibapi.proto.Contract
    const d = item.contractDetails.?;   // ibapi.proto.ContractDetails
    std.debug.print("{?d} {s} {s}\n", .{ c.conId, c.primaryExch orelse "", d.longName orelse "" });
}
```

`conId` z výsledku identifikuje kontrakt jednoznačně a je nejlepší způsob,
jak se na něj odkazovat v dalších požadavcích (`Query.byConId`).

Když nic neodpovídá, TWS vrátí chybu 200 a volání skončí s
`error.RequestRejected`. Kód a text chyby získáte přes `Diagnostics`:

```zig
var diag: ibapi.Client.Diagnostics = .{};
_ = client.contractDetails(gpa, query, .{ .diagnostics = &diag }) catch |err| switch (err) {
    error.RequestRejected => std.debug.print("TWS error {d}: {s}\n", .{ diag.code, diag.message() }),
    else => return err,
};
```

Dotaz na všechny opce jednoho symbolu vrátí tisíce kontraktů a může trvat
desítky sekund; limit zvýšíte přes `.{ .timeout = .fromSeconds(60) }`.
Když požadavek vyprší, knihovna požádá TWS, aby zbytek neposílal.

## Hledání symbolů

```zig
var matches = try client.searchSymbols(gpa, "apple", .{});
defer matches.deinit();
for (matches.items()) |m| { ... m.contract, m.derivativeSecTypes ... }
```

Vzor se porovnává se začátkem symbolů a s názvy firem. TWS vrátí nejvýše
několik desítek výsledků.

## Opční řetězce

`optionChainParams` vrátí pro každou burzu a obchodní třídu opcí na dané
podkladové aktivum multiplikátor, všechny expirace a všechny strikes. I pro
symboly s tisíci opcí je to jedna krátká odpověď.

```zig
var chain = try client.optionChainParams(gpa, .{ .symbol = "AAPL", .con_id = 265598 }, .{});
defer chain.deinit();
for (chain.items) |p| {
    // p.exchange, p.tradingClass, p.multiplier,
    // p.expirations.items ([]const u8, YYYYMMDD), p.strikes.items (f64)
}
```

`con_id` podkladového aktiva je povinné; získáte ho z `contractDetails`.
Pro indexy a futures nastavte `.sec_type = .index` / `.future`. Některá
podkladová aktiva mají víc obchodních tříd, např. `SPX` (měsíční) a `SPXW`
(týdenní).

**Strikes jsou sjednocení přes všechny expirace** — konkrétní expirace nemusí
mít každý strike. Skutečné strikes jedné expirace zjistíte dotazem na její
kontrakty; u akciových opcí stačí cally:

```zig
var calls = try client.contractDetails(gpa,
    Query.option("AAPL", "USD", "20261218", null, .call), .{ .timeout = .fromSeconds(30) });
defer calls.deinit();
// calls.items[i].contract.?.strike, .conId
```

TWS neumí filtrovat podle rozsahu dat. Chcete-li třeba expirace do 45 dnů,
vezměte expirace z `optionChainParams`, vyberte potřebné a pro každou se
zeptejte na detaily kontraktů. Přesně to ukazuje `examples/option_chain.zig`.

## Ukázkové programy

`examples/contracts.zig` a `examples/option_chain.zig`:

```sh
zig build examples
./zig-out/bin/contracts search apple
./zig-out/bin/contracts details AAPL
./zig-out/bin/contracts details AAPL OPT USD 20261218
./zig-out/bin/option_chain AAPL 45
```
