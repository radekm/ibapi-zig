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

## Ukázkový program

`examples/contracts.zig`:

```sh
zig build examples
./zig-out/bin/contracts search apple
./zig-out/bin/contracts details AAPL
./zig-out/bin/contracts details AAPL OPT USD 20261218
```
