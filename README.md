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
- The `.proto` files of the TWS API — developed and tested with
  **TWS API 10.52.01**

## Getting the `.proto` files

The `.proto` files are published by Interactive Brokers under the GPL v3
and are **not included** in this repository. Download the TWS API from
<https://interactivebrokers.github.io/> and unpack it; the files are in
`source/proto` (or in `proto` of the standalone protobuf archive).

## Building

```sh
zig build test -Dproto-dir=/path/to/twsapi/source/proto
```

The build runs `protoc` with the [zig-protobuf](https://github.com/Arwalk/zig-protobuf)
generator and puts the generated Zig code into the build cache. By default
zig-protobuf downloads `protoc` 36.2; use `-Dprotoc=/path/to/protoc` to use
your own.

## Using it as a dependency

```sh
zig fetch --save "git+https://github.com/radekm/ibapi-zig#main"
```

In `build.zig`:

```zig
const ibapi_dep = b.dependency("ibapi_zig", .{
    .target = target,
    .optimize = optimize,
    .@"proto-dir" = "/path/to/twsapi/source/proto",
});
exe.root_module.addImport("ibapi", ibapi_dep.module("ibapi"));
```

## License

ibapi-zig is licensed under the [zlib license](LICENSE).

The TWS API `.proto` files you supply are © Interactive Brokers LLC and
licensed under the GPL v3 or later. Code generated from them and programs
that include it may be subject to that license — check this for your use case.
