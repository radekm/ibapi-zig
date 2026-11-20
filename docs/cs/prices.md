# Ceny akcií a opcí

[English version](../en/prices.md)

ibapi-zig dělá jen **snapshoty**: jeden požadavek, jedna odpověď s aktuálními
hodnotami. Průběžné subskripce záměrně podporované nejsou.

```zig
const Query = ibapi.contract.Query;

const stock = try client.snapshot(Query.stock("AAPL", "USD"), .{});
std.debug.print("bid {?d} ask {?d} last {?d}\n", .{ stock.bid, stock.ask, stock.last });

const option = try client.snapshot(Query.option("AAPL", "USD", "20261218", 190, .call), .{});
if (option.model_computation) |m| {
    std.debug.print("iv {?d} delta {?d} theta {?d}\n", .{ m.implied_vol, m.delta, m.theta });
}
```

Na kontrakt nalezený přes `contractDetails` se nejlépe odkážete jeho id:
`Query.byConId(con_id, "SMART")`.

## Co snapshot obsahuje

`ibapi.market_data.Quote` — každé pole je volitelné (`null`, pokud ho TWS
neposlalo):

| Pole | Význam |
| --- | --- |
| `bid`, `bid_size`, `ask`, `ask_size` | nejlepší nákup a prodej |
| `last`, `last_size`, `last_timestamp` | poslední obchod (čas v Unix sekundách) |
| `open`, `high`, `low` | dnešní |
| `close` | závěr předchozího obchodního dne |
| `volume` | dnešní objem |
| `data_type` | `.live` nebo `.frozen`, jak ho nahlásilo TWS (zpožděná data ukončí snapshot s `error.RequestRejected`) |
| `bid_computation`, `ask_computation`, `last_computation`, `model_computation` | hodnoty pro opce, viz níže |

`quote.mid()` vrací střed mezi bid a ask.

## Greeks a implikovaná volatilita

U opcí hodnoty počítá TWS **svým vlastním opčním modelem**; knihovna nic
nepočítá. Přicházejí až ve čtyřech variantách podle toho, z jaké ceny opce
vycházejí:

- `bid_computation`, `ask_computation`, `last_computation` — implikovaná
  volatilita (a greeks) dopočítaná z bidu, asku nebo poslední ceny opce;
- `model_computation` — modelová volatilita IB a z ní modelová cena
  (`option_price`). Pro greeks se obvykle používá tato varianta.

Každá varianta (`ibapi.market_data.OptionComputation`) má `implied_vol`,
`delta`, `gamma`, `vega`, `theta`, `option_price`, `pv_dividend` (současná
hodnota očekávaných dividend) a `underlying_price` (použitá cena podkladu).
Hodnoty, které TWS spočítat nedokázalo, jsou `null`: TWS je označuje
hodnotou -1 (ceny, volatilita) nebo -2 (řecká písmena). Dokumentace IB tyto
značky nepopisuje; knihovna se tu řídí referenčním C++ klientem od IB.

## Live nebo frozen data

`Client.Options.market_data_type` určuje data pro celé spojení:

- `.frozen` (výchozí) — během obchodování živá data, jinak poslední hodnoty
  ze závěru. Hodí se, když potřebujete ceny i mimo obchodní hodiny.
- `.live` — jen data v reálném čase.

Obojí vyžaduje předplatné tržních dat pro daný instrument (pro americké opce
OPRA). Bez něj snapshot skončí s `error.RequestRejected` a v diagnostice je
chyba TWS 354. TWS může místo toho přejít na zpožděná data (varování 2186
nebo 10167, případně zpožděný typ dat; pozorováno na paper účtu během
amerických obchodních hodin). Knihovna zpožděná data nikdy nepřijímá, takže
i to skončí s `error.RequestRejected`: s kódem 2186 / 10167 a jeho textem,
nebo s kódem 0 a zprávou, která typ dat pojmenuje. Chyba 10090 (část dat
není předplacená) je jen varování a snapshot neukončí.

## Časové limity

TWS může snapshot dokončovat až zhruba 11 sekund, proto je výchozí limit
`Client.Options.snapshot_timeout` = 15 s. Pro jedno volání ho změníte přes
`.{ .timeout = .fromSeconds(30) }`. Když limit vyprší, požadavek se v TWS
zruší.

## Víc kontraktů

Snapshoty mohou na jednom spojení běžet souběžně:

```zig
var a = io.async(ibapi.Client.snapshot, .{ client, Query.stock("AAPL", "USD"), .{} });
var b = io.async(ibapi.Client.snapshot, .{ client, Query.stock("MSFT", "USD"), .{} });
const qa = try a.await(io);
const qb = try b.await(io);
```

TWS omezuje počet současných požadavků na tržní data (obvykle 100).

## Ukázkový program

`examples/quote.zig`:

```sh
./zig-out/bin/quote AAPL
./zig-out/bin/quote AAPL 20261218 190 C
```
