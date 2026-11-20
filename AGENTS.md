# AGENTS.md — rules for working on ibapi-zig

These rules apply to every contributor, human or AI agent. Read this file and
`PLAN.md` before making changes.

## Communication

- Chat with the project owner in **Czech**.
- Code, identifiers, code comments and commit messages are in **English**.
- User documentation is written in **both English and Czech**, in separate
  files that link to each other: `README.md` + `README.cs.md`, and
  `docs/en/…` + `docs/cs/…`. Both versions must be kept in sync in the same
  commit. `AGENTS.md` and `PLAN.md` are internal and stay English only.
- When unsure about anything (API design, IB protocol behaviour, scope), **ask**
  instead of guessing.

## Toolchain and dependencies

- Language: **Zig 0.17.1** exactly. Do not use features from `master`.
- Allowed dependencies: **only** [zig-protobuf](https://github.com/Arwalk/zig-protobuf)
  (and the `protoc` binaries it fetches lazily). Adding any other dependency
  requires explicit approval from the owner first.
- Dependencies are pinned in `build.zig.zon` by URL + hash.

## Protocol scope

- The library speaks **only the protobuf variant** of the TWS API.
  Minimum server version is **213** (`PROTOBUF_REST_MESSAGES_3`, TWS / IB Gateway 10.40+).
  Connecting to an older server fails right after the handshake with
  `error.ServerVersionTooOld`. No fallback to the legacy text protocol.
- The `.proto` files from IB are **not committed**. The Zig code generated
  from them **is committed** in `src/proto/protobuf.pb.zig`, so building
  and testing need neither the `.proto` files nor protoc.
- The reference version is **TWS API 10.52.01**. To update, run
  `zig build gen-proto -Dproto-dir=<twsapi>/source/proto` and commit the
  result together with the version change in the READMEs.
- Never edit `src/proto` by hand; it is excluded from `zig fmt`.
- Do not copy code from IB's clients or other TWS API libraries into this
  repository; use them only as a reference for protocol behaviour.

## License

- The repository is licensed under **zlib** (`LICENSE`). Every contribution
  must be compatible with it.

## Safety

- Phase 1 of the project is **read-only**. Code must never place, modify or
  cancel orders until the plan explicitly reaches that phase.
- Integration tests run only against a **paper trading** account and are
  opt-in (`zig build test-integration`). They must never send order-changing
  requests.
- Never commit credentials, account numbers, host names of private machines
  or recorded data containing account identifiers. Anonymise captured
  messages used as test fixtures.

## Architecture rules

- Concurrency and I/O go through **`std.Io`** (passed in by the caller as
  `io: std.Io`). Never call blocking OS APIs directly, never spawn raw threads.
- Every allocating function takes an explicit `std.mem.Allocator`.
  Document who owns returned memory and how to free it.
- Public API is split into:
  - `ibapi.wire` — framing and handshake (no knowledge of individual messages),
  - `ibapi.proto` — generated protobuf types (re-exported),
  - `ibapi.Client` — the asynchronous client (request routing, typed results).
- Errors from TWS (`ErrorMessage`) that belong to a request are delivered to
  that request's caller; others go to the client's notice stream.
  Do not silently drop them.
- No global mutable state.
- **Every operation that waits must have a timeout**: connecting, each
  request, each write, waiting for notices or subscription data. Defaults
  live in `Client.Options`; waiting forever is never the default. The only
  exception is the internal reader task idling between messages, because
  every caller waiting for its results has its own deadline.

## Code style

- Run `zig fmt` on all sources (except the generated `src/proto`); CI rejects
  unformatted code.
- Every public declaration has a `///` doc comment.
- Prefer small files with one responsibility; tests live next to the code
  (`test "..." {}` blocks) unless they need fixtures.
- Use `std.log.scoped(.ibapi)` for logging; the library never prints to stdout.

## Testing

- `zig build test` must pass before every commit (CI runs it too). It runs unit tests and
  tests against an in-process **fake TWS server** that replays recorded frames.
- New message support = encoder/decoder tests + at least one fake-server test.
- `zig build test-integration` (opt-in) needs a running paper TWS / Gateway;
  the connection comes from `Config.zon` in the current working directory
  (as for the examples; template `examples/Config.example.zon`, ignored by git).

## Workflow

- Work in small steps that follow `PLAN.md`. After finishing a step, tick it
  in `PLAN.md` in the same commit.
- If the plan turns out to be wrong, update `PLAN.md` (and tell the owner)
  before diverging from it.
- Commit messages: imperative mood, short summary line, body explaining *why*.
- Use **only the `main` branch**. Do not create other branches or PRs.
