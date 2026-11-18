# ibapi-zig

[Česká verze](README.cs.md)

A Zig library for Interactive Brokers: it talks to Trader Workstation (TWS)
or IB Gateway using the **protobuf** variant of the TWS API.

> **Status:** early development. The first goal is read-only access:
> contract lookup, prices of stocks and options, and the list of open orders.
> Placing, modifying and cancelling orders will come later.
> See [PLAN.md](PLAN.md).

## Requirements

- Zig **0.17.1**
- TWS or IB Gateway **10.40 or newer** (server version ≥ 213) with the API enabled

## Building

```sh
zig build test
```

## Protobuf messages

The Zig types of the TWS API messages are generated from the `.proto` files
of **TWS API 10.52.01** with [zig-protobuf](https://github.com/Arwalk/zig-protobuf)
and committed in `src/proto/protobuf.pb.zig`. The `.proto` files themselves
are not part of this repository.

To regenerate them for another TWS API release, download it from
<https://interactivebrokers.github.io/>, unpack it and run:

```sh
zig build gen-proto -Dproto-dir=/path/to/twsapi/source/proto
```

By default zig-protobuf downloads `protoc` 36.2; use `-Dprotoc=/path/to/protoc`
to use your own.

## Using it as a dependency

```sh
zig fetch --save "git+https://github.com/radekm/ibapi-zig#main"
```

In `build.zig`:

```zig
const ibapi_dep = b.dependency("ibapi_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ibapi", ibapi_dep.module("ibapi"));
```

## Usage

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

Every operation has a timeout: `connect_timeout`, `request_timeout`,
`snapshot_timeout` and `write_timeout` in `ibapi.Client.Options`
(defaults 10 s, 10 s, 15 s and 5 s),
and `nextNotice` takes one explicitly. Timeouts are reported as `error.Timeout`.

Requests can run concurrently on one connection, e.g.
`var f = io.async(ibapi.Client.currentTime, .{client});` and later `try f.await(io)`.
Messages that belong to no request (informational errors etc.) are read with
`client.nextNotice(timeout)`.

## Guides

- [Looking up contracts and option chains](docs/en/contracts.md)
- [Prices of stocks and options](docs/en/prices.md)
- [Orders (read-only)](docs/en/orders.md)
- [Wire protocol](docs/en/protocol.md)

## Examples

```sh
zig build examples
export IBAPI_HOST=127.0.0.1 IBAPI_PORT=7497 IBAPI_CLIENT_ID=1   # defaults
./zig-out/bin/connect
./zig-out/bin/contracts details AAPL
./zig-out/bin/option_chain AAPL 45
./zig-out/bin/quote AAPL 20261218 190 C
./zig-out/bin/orders
```

## License

ibapi-zig is licensed under the [zlib license](LICENSE).
The message definitions in `src/proto` are generated from the TWS API
`.proto` files by Interactive Brokers LLC.
