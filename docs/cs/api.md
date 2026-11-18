# Metody klienta a jejich zprávy

[English version](../en/api.md)

Jaké protobuf zprávy (`ibapi.proto`) každá metoda `ibapi.Client` posílá do TWS
a jaké přijímá. Číslo v závorce je id zprávy; na drátě nesou protobuf zprávy
id + 200 (viz [protocol.md](protocol.md)). Každá metoda může navíc dostat
`ErrorMessage` (4), viz [Chyby](#chyby-errormessage).

Úplná referenční dokumentace API se generuje z doc komentářů příkazem
`zig build docs` (`zig-out/docs/index.html` otevřete přes lokální webový
server, např. `python3 -m http.server -d zig-out/docs`).

## Spojení

| Metoda | Posílá | Přijímá |
| --- | --- | --- |
| `connect` | textové hello `API\0` + rozsah verzí; `StartApiRequest` (71); `MarketDataTypeRequest` (59) | textové hello serveru (verze, čas); `ManagedAccounts` (15); `NextValidId` (9) — ukončí handshake; cokoli jiného před ním jde do notices |
| `close` | — (zavře socket) | — |
| `serverVersion`, `connectionTime`, `managedAccounts`, `nextOrderId` | — (hodnoty z handshaku; `nextOrderId` aktualizuje každé `NextValidId`) | — |
| `nextNotice` | — | jakákoli zpráva, na kterou nečeká žádný požadavek (viz [Notices](#notices)) |

## Požadavky

| Metoda | Posílá | Přijímá (končí zprávou) | Směrování |
| --- | --- | --- | --- |
| `currentTime` | `CurrentTimeRequest` (49) | `CurrentTime` (49) | druh |
| `contractDetails` | `ContractDataRequest` (9); při vypršení `CancelContractData` (106), server ≥ 215 | `ContractData` (10), `ContractData` pro dluhopisy (18), **`ContractDataEnd` (52)** | `reqId` |
| `searchSymbols` | `MatchingSymbolsRequest` (81) | **`SymbolSamples` (79)** | `reqId` |
| `optionChainParams` | `SecDefOptParamsRequest` (78) | `SecDefOptParameter` (75), **`SecDefOptParameterEnd` (76)** | `reqId` |
| `snapshot` | `MarketDataRequest` (1) se `snapshot = true`; při vypršení `CancelMarketData` (2) | `TickPrice` (1), `TickSize` (2), `TickString` (46), `TickGeneric` (45), `TickOptionComputation` (21), `TickReqParams` (81), `MarketDataType` (58), **`TickSnapshotEnd` (57)** | `reqId` |
| `openOrders` | `AllOpenOrdersRequest` (16) | `OpenOrder` (5), `OrderStatus` (3), **`OpenOrdersEnd` (53)** | druh |
| `completedOrders` | `CompletedOrdersRequest` (99) | `CompletedOrder` (101), **`CompletedOrdersEnd` (102)** | druh |

*Směrování podle `reqId`*: odpovědi nesou id požadavku, takže takových
požadavků může běžet současně libovolně mnoho. *Směrování podle druhu*:
odpovědi id požadavku nenesou; požadavky čekající na stejný druh zprávy
dostanou odpovědi v pořadí, v jakém byly odeslány.

## Nízkoúrovňové metody

Pro zprávy, které knihovna zatím neobaluje:

| Metoda | Účel |
| --- | --- |
| `send(id, msg)` | pošle libovolný požadavek uvedený ve `ibapi.wire.OutMsg` |
| `register(r, key, end, buffer, timeout)` | začne sbírat zprávy podle `reqId` (`.req_id`) nebo podle druhu (`.kinds`) do `Client.Responses` |
| `registerKindsAndSend(…)` | `register` podle druhu + `send` jako jeden krok, zachová pořadí požadavků |
| `nextRequestId()` | nové id požadavku |

`wire.OutMsg` obsahuje jen požadavky, které nic nemění. Požadavky na zadání,
změnu nebo zrušení příkazu v něm nejsou, stejně jako `ReqOpenOrders` (5),
který pro client id 0 přiváže ruční příkazy z TWS.

## Chyby (`ErrorMessage`)

- Chyba, jejíž `id` je id čekajícího požadavku, ukončí tento požadavek
  s `error.RequestRejected`; kód a text jsou v `RequestOptions.diagnostics`.
- Varování požadavek neukončí a jen se zalogují: kódy 2100–2199 (stav
  spojení), 10090 a 10167 (tržní data).
- Chyby s `id = -1` nebo s id, na které nečeká žádný požadavek, jdou do notices.

## Notices

`nextNotice(timeout)` vrací zprávy, které nepatří žádnému čekajícímu
požadavku: informační chyby (např. 2104 „Market data farm connection is OK“),
`NextValidId`, aktualizace příkazů poslané po `openOrders` (`OpenOrder`,
`OrderStatus`), pozdní odpovědi požadavků, kterým vypršel limit, a zprávy,
které knihovna nedekóduje (`Incoming.other`). Drží se nejvýš
`notice_capacity` (256) nepřečtených notices; novější se zahodí a spočítá
je `droppedNotices()`.

## Limity

- Každý požadavek má časový limit (`Options.request_timeout`, pro `snapshot`
  `Options.snapshot_timeout`, nebo `.timeout` volání).
- Klient pošle nejvýš `Options.max_messages_per_second` (výchozí 50) zpráv
  za sekundu; další zprávy počkají. Kdyby čekání přesáhlo
  `Options.write_timeout`, `send` skončí s `error.Timeout` a spojení se
  nedotkne.
- Klient se znovu nepřipojuje. Při ztrátě spojení skončí čekající i další
  požadavky s `error.ConnectionClosed` nebo `error.ConnectionLost`; klienta
  zavřete a připojte se znovu.
