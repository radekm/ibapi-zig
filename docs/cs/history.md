# Historické svíčky (OHLC)

[English version](../en/history.md)

ibapi-zig stahuje **minutové** a **denní** svíčky. Větší svíčky (5 minut,
hodina, týden) se z nich snadno poskládají agregací. Každý požadavek je
jednorázový: knihovna nikdy nežádá TWS o průběžnou aktualizaci svíček
(`keepUpToDate`), protože to by byla subskripce.

```zig
const history = ibapi.history;
const Query = ibapi.contract.Query;

// Minutové svíčky za poslední hodinu.
const now = std.Io.Timestamp.now(io, .real);
var minutes = try client.minuteBars(gpa, Query.stock("AAPL", "USD"), .{
    .start = now.subDuration(.fromSeconds(3600)),
}, .{});
defer minutes.deinit();
for (minutes.items) |b| {
    std.debug.print("{d} {?d} {?d} {?d} {?d} {?d}\n", .{ history.floorSeconds(b.time), b.open, b.high, b.low, b.close, b.volume });
}

// Denní svíčky za leden 2025.
var days = try client.dailyBars(gpa, Query.stock("AAPL", "USD"), .{
    .first = try history.day(2025, 1, 2),
    .last = try history.day(2025, 1, 31),
}, .{});
defer days.deinit();
```

Stejně jako u `snapshot` je potřeba předplatné tržních dat pro daný
kontrakt; bez něj TWS požadavek odmítne (`error.RequestRejected`).
Forex a kryptoměny předplatné nepotřebují; forex nemá obchody, takže pro
měnové páry použijte `.what_to_show = .midpoint` (nebo `.bid`, `.ask`),
např. `Query.forex("EUR", "USD")`.

## Které svíčky se vrátí

| Metoda | Rozsah | Čas svíčky |
| --- | --- | --- |
| `minuteBars` | svíčky, jejichž **začátek** leží v `[start, end)`; `end = null` znamená teď | `time: std.Io.Timestamp` — začátek svíčky, okamžik (UTC) |
| `dailyBars` | obchodní dny `first..last`, **oba včetně**; `last = null` znamená dnes | `day: history.Day` (`std.time.epoch.EpochDay`) — obchodní den burzy, bez času a časové zóny |

Příklady pro `minuteBars`:

- `start = 17:23:15`, `end = 17:30:00` → svíčky 17:24 … 17:29. Svíčka 17:23
  začala před `start`, takže ve výsledku není; svíčka 17:29 pokrývá
  17:29–17:30.
- Chcete-li i svíčku, která `start` obsahuje, zaokrouhlete `start` dolů na
  celou minutu.
- Při `end = null` může být ve výsledku i právě probíhající, nedokončená
  svíčka (její hodnoty se ještě mění). Totéž platí pro dnešní svíčku
  v `dailyBars`.

`history.day(rok, měsíc, den)` vytvoří `Day`;
`d.calculateYearDay().calculateMonthDay()` ho převede zpět na datum.

Výsledek je seřazený od nejstarší svíčky a bez duplicit. Dny a minuty bez
obchodování (noci, víkendy, svátky, data starší, než IB uchovává) prostě
nemají svíčky; prázdný rozsah není chyba.

## Pole svíčky

`history.MinuteBar` a `history.DailyBar`:

| Pole | Význam |
| --- | --- |
| `open`, `high`, `low`, `close` | ceny (viz `what_to_show`) |
| `volume` | zobchodovaný objem; jen pro `.trades` |
| `wap` | objemově vážená průměrná cena; jen pro `.trades` |
| `count` | počet obchodů; jen pro `.trades` |

Všechna pole jsou volitelná (`null`, když je TWS neposlalo). IB pro svíčky
nedokumentuje žádné speciální hodnoty, takže je knihovna nijak nevykládá.

## Z čeho se svíčky skládají (`what_to_show`)

| Hodnota | Svíčky |
| --- | --- |
| `.trades` (výchozí) | obchody; jediný druh s objemem, WAP a počtem obchodů |
| `.midpoint` | střed mezi bid a ask |
| `.bid`, `.ask` | ceny bid nebo ask |
| `.bid_ask` | **zvláštní význam**: `open` = časový průměr bidu, `high` = nejvyšší ask, `low` = nejnižší bid, `close` = časový průměr asku. IB tyto požadavky započítává do limitů dvakrát. |
| `.adjusted_last` | obchody upravené o splity a dividendy; `end` / `last` musí být null (IB vyžaduje, aby požadavek končil teď) a rozsah `minuteBars` nejvýš jeden den |
| `.historical_volatility` | historická volatilita |
| `.option_implied_volatility` | implikovaná volatilita opcí |

`use_rth` (výchozí `true`) omezí svíčky na běžné obchodní hodiny.

## Požadavky posílané do TWS a limity

- `minuteBars` žádá v jednom požadavku nejvýš jeden den (86 400 s). Delší
  rozsah se rozdělí na požadavky po jednom dni, které se posílají postupně
  od konce a překrývají se o jednu svíčku. `endDateTime` se posílá v UTC
  (`YYYYMMDD-HH:mm:ss`) a časy svíček jako Unixové sekundy, takže na
  časové zóně nastavené v TWS nezáleží.
- `dailyBars` je jeden požadavek (`N D` do jednoho roku, nad ním `N Y`).
- `opts.timeout` (výchozí `Options.historical_timeout`, 60 s) platí pro
  každý požadavek poslaný do TWS; TWS historické požadavky může zpomalovat.
- Najednou je otevřeno nejvýš `Options.max_historical_requests` (50, limit
  IB) historických požadavků; další čekají na volné místo, v rámci svého
  timeoutu.
- Při vypršení nebo zrušení úlohy se požadavek v TWS zruší
  (`CancelHistoricalData`).
- Chyba 162, jejíž text říká, že dotaz „returned no data“, znamená prázdný
  výsledek. Jakákoli jiná chyba (např. 162 pacing violation) ukončí volání
  s `error.RequestRejected` a podrobnostmi v `opts.diagnostics`.
- Přísná pravidla IB (60 požadavků za 10 minut, stejný požadavek do 15 s)
  platí pro svíčky do 30 sekund, které knihovna nenabízí. U minutových
  a větších svíček IB jen zpomaluje klienty, kteří chtějí příliš mnoho;
  mezi požadavky se nečeká.

Ukázka `zig-out/bin/bars AAPL minutes 2` / `bars AAPL days 30` vypíše
svíčky akcie.
