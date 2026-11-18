# TWS API wire protocol (protobuf variant)

[Česká verze](../cs/protocol.md)

This is a description of the protocol as ibapi-zig uses it. It was verified
against the reference C++ client of TWS API 10.52.01.

## Versions

- During the handshake the client offers a range of protocol versions;
  ibapi-zig offers `v100..226`.
- The server answers with the version it picked (the *server version*).
- From server version 201 message ids are sent as binary integers.
- Each request switched to protobuf at a specific server version. With
  server version **213** every request ibapi-zig needs (including StartApi,
  ReqIds and ReqCurrentTime) is protobuf, so 213 is the minimum we accept.

## Handshake

1. Client → server: the 4 bytes `A P I 0x00`, then a frame (see below without
   a message id) whose payload is the ASCII text `v100..226`.
   Optional connect options may follow after a space.
2. Server → client: a frame whose payload is two NUL-terminated ASCII
   fields: the server version (decimal) and the connection time
   (e.g. `20261118 16:54:00 Europe/Prague`).
3. Client → server: a StartApi message (id 71, protobuf `StartApiRequest`
   with the client id).
4. Server → client: among others `NextValidId` and `ManagedAccounts`.
   After `NextValidId` the connection is ready for requests.

## Frames

Every message after the handshake is a frame:

| Bytes | Content |
| --- | --- |
| 4 | payload length *n*, big-endian, max `0xFFFFFF` |
| 4 | message id, big-endian (part of the payload length) |
| *n* − 4 | message body |

If the message id is greater than 200, the body is protobuf and the real id
is `id − 200`. Otherwise the body is in the legacy text format
(NUL-terminated fields); ibapi-zig does not decode such messages and only
reports them as unhandled.

Outgoing protobuf messages are always sent with `id + 200`.

## Message ids

Incoming and outgoing messages have separate id spaces. The ids used by
ibapi-zig are listed in `src/wire.zig` (`wire.InMsg`, `wire.OutMsg`).

## Errors

`ErrorMessage` (incoming id 4) carries `id`, `errorCode` and `errorMsg`.
`id` is the request id (or order id) the error belongs to; `-1` means the
error is not tied to a request. Some codes are only informational, e.g.
2104/2106/2158 (data farm connection is OK).
