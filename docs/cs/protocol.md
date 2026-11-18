# Síťový protokol TWS API (protobuf varianta)

[English version](../en/protocol.md)

Popis protokolu tak, jak ho používá ibapi-zig. Ověřeno proti referenčnímu
C++ klientovi z TWS API 10.52.01.

## Verze

- Při handshaku klient nabídne rozsah verzí protokolu; ibapi-zig nabízí
  `v100..226`.
- Server odpoví verzí, kterou zvolil (*server version*).
- Od server version 201 se čísla zpráv posílají jako binární celá čísla.
- Každý požadavek přešel na protobuf od určité server version. Od verze
  **213** jsou protobufem všechny požadavky, které ibapi-zig potřebuje
  (včetně StartApi, ReqIds a ReqCurrentTime), proto je 213 minimum.

## Handshake

1. Klient → server: 4 bajty `A P I 0x00`, pak rámec (viz níže, bez čísla
   zprávy), jehož obsahem je ASCII text `v100..226`. Za mezerou mohou
   následovat volitelné parametry připojení.
2. Server → klient: rámec se dvěma ASCII poli ukončenými nulovým bajtem:
   server version (desítkově) a čas připojení
   (např. `20261118 16:54:00 Europe/Prague`).
3. Klient → server: zpráva StartApi (číslo 71, protobuf `StartApiRequest`
   s client id).
4. Server → klient: mimo jiné `NextValidId` a `ManagedAccounts`.
   Po `NextValidId` je spojení připravené na požadavky.

## Rámce

Každá zpráva po handshaku je rámec:

| Bajty | Obsah |
| --- | --- |
| 4 | délka obsahu *n*, big-endian, max. `0xFFFFFF` |
| 4 | číslo zprávy, big-endian (započítává se do délky) |
| *n* − 4 | tělo zprávy |

Je-li číslo zprávy větší než 200, tělo je protobuf a skutečné číslo je
`číslo − 200`. Jinak je tělo ve starém textovém formátu (pole ukončená
nulovým bajtem); ibapi-zig takové zprávy nedekóduje a jen je hlásí jako
nezpracované.

Odchozí protobuf zprávy se vždy posílají s číslem `číslo + 200`.

## Čísla zpráv

Příchozí a odchozí zprávy mají vlastní číselné řady. Čísla, která ibapi-zig
používá, jsou v `src/wire.zig` (`wire.InMsg`, `wire.OutMsg`).

## Chyby

`ErrorMessage` (příchozí číslo 4) nese `id`, `errorCode` a `errorMsg`.
`id` je číslo požadavku (nebo příkazu), ke kterému chyba patří; `-1`
znamená, že chyba k žádnému požadavku nepatří. Některé kódy jsou jen
informativní, např. 2104/2106/2158 (spojení s datovou farmou je v pořádku).
