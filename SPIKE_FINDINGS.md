# grpc-swift Windows Spike — Full Findings Handoff

**Date completed:** 2026-06-22  
**Repo:** `brianm998/gprc_windows_test` (branch: `develop`)  
**Purpose:** Validate whether grpc-swift 2 can build and run on Windows/Linux/macOS via GitHub Actions CI, before committing to the "headless Swift daemon + gRPC" architecture described in `CROSS_PLATFORM_DAEMON_DESIGN.md`.

---

## What was built

A minimal Swift package containing:

| File | Purpose |
|---|---|
| `Package.swift` | grpc-swift 2.2.3 + NIO transport 1.2.3 + protobuf 1.38.0 |
| `proto/spike.proto` | `Echo` service: one unary RPC + one server-streaming RPC |
| `Sources/SpikeProto/spike.pb.swift` | Pre-generated protobuf stubs (committed, not regenerated in CI gate) |
| `Sources/SpikeProto/spike.grpc.swift` | Pre-generated gRPC stubs (committed) |
| `Sources/SpikeServer/main.swift` | Binds ephemeral port 0, prints `{"event":"listening","port":N,"pid":P}` to stdout |
| `Sources/SpikeClient/main.swift` | Reads port from `argv[1]`, runs unary + streaming RPC, exits 0 on success |
| `Tests/SpikeTests/InProcessTests.swift` | In-process loopback test (sanity only, `continue-on-error` in CI) |
| `scripts/run_spike.py` | Cross-platform Python harness: spawns server, reads handshake, runs client, asserts |
| `scripts/generate.sh` | Dev-only stub regeneration (not run in CI gate) |
| `.github/workflows/spike.yml` | Matrix CI: `ubuntu-latest`, `macos-15`, `windows-2022` |

---

## CI configuration decisions (and why)

### Swift version: 6.1 (not 6.0)

The spike plan specified Swift 6.0, but `windows-latest` now maps to `windows-2025-vs2026` (Windows Server 2025, Visual Studio 2026 / MSVC 14.51). Swift 6.0's Clang-based C importer triggers a **cyclic dependency** in the MSVC `ucrt` module during `swift package resolve`:

```
error: cyclic dependency in module 'ucrt': ucrt -> _visualc_intrinsics -> ucrt
```

This happens during manifest compilation of transitive dependencies (e.g., `swift-asn1`). Swift 6.1 fixed this MSVC header compatibility issue.

### Runner: `macos-15` (not `macos-14`)

With Swift 6.1's strict concurrency, `swift-nio 2.101.0` fails on macOS 14 with:

```
NIOEmbedded/AsyncTestingEventLoop.swift:85:24: error: static property 'inQueueKey' is not
concurrency-safe because non-'Sendable' type 'DispatchSpecificKey<ObjectIdentifier>' may
have shared mutable state
```

The `NIOEmbedded` module uses `DispatchSpecificKey` (Apple Dispatch framework). The macOS 14 SDK does not annotate `DispatchSpecificKey` as `Sendable`. The macOS 15 SDK does. Linux is unaffected because Dispatch is not available there.

### Runner: `windows-2022` (not `windows-latest`)

Even with Swift 6.1 (which fixes the `swift package resolve` crash), `windows-latest` (VS 2026) still fails during `swift build` with:

```
yvals_core.h:917:1: error: static assertion failed:
error STL1000: Unexpected compiler version, expected Clang 20 or newer.
```

VS 2026's C++ Standard Library headers assert that the Clang version is ≥ 20. Swift 6.1 ships Clang 19. This is a hard incompatibility between the Swift 6.x toolchain and VS 2026 headers, not fixable by flags. `windows-2022` (VS 2022 / MSVC 14.3x) has no such constraint and works with Swift 6.1.

### Stub generation: public visibility required

The locally-installed `protoc-gen-grpc-swift` generated stubs with `internal` access. Types are `internal` to `SpikeProto` and invisible to `SpikeServer`/`SpikeClient`. The fix: regenerate with `Visibility=Public:` output option. Additionally, the system-installed plugin version was ahead of grpc-swift 2.2.3 and generated `MethodDescriptor(service:method:type:)` calls that don't exist in 2.2.3. The fix: build `protoc-gen-grpc-swift` from the resolved `.build/checkouts/grpc-swift-protobuf` checkout and use that plugin explicitly:

```bash
PLUGIN=.build/checkouts/grpc-swift-protobuf/.build/debug/protoc-gen-grpc-swift
protoc \
  --proto_path=proto \
  --plugin=protoc-gen-grpc-swift=$PLUGIN \
  --swift_out=Visibility=Public:Sources/SpikeProto \
  --grpc-swift_out=Visibility=Public:Sources/SpikeProto \
  proto/spike.proto
```

### Swift 6 concurrency: streaming closure returns count

The plan's template used a `var received = 0` captured by an `@Sendable` closure. Swift 6 strict concurrency disallows mutating a captured `var` from a `@Sendable` closure. Fixed by returning the count from the closure instead:

```swift
// before (doesn't compile under Swift 6)
var received = 0
try await echo.streamEcho(msg) { stream in
    for try await _ in stream.messages { received += 1 }
}

// after
let received = try await echo.streamEcho(msg) { stream -> Int in
    var count = 0
    for try await _ in stream.messages { count += 1 }
    return count
}
```

---

## Actual API shape (grpc-swift 2.2.3 + grpc-swift-nio-transport 1.2.3)

These are the real names from the resolved packages — use these in any follow-on implementation.

**Service implementation** (server):
```swift
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct EchoService: Spike_V1_Echo.SimpleServiceProtocol {
    func unaryEcho(
        request: Spike_V1_EchoRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Spike_V1_EchoResponse { ... }

    func streamEcho(
        request: Spike_V1_EchoRequest,
        response: GRPCCore.RPCWriter<Spike_V1_EchoResponse>,
        context: GRPCCore.ServerContext
    ) async throws { ... }
}
```

**Server transport** (bind port 0, read bound address):
```swift
let transport = HTTP2ServerTransport.Posix(
    address: .ipv4(host: "127.0.0.1", port: 0),
    transportSecurity: .plaintext
)
let server = GRPCServer(transport: transport, services: [EchoService()])

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await server.serve() }
    let address = try await transport.listeningAddress  // async throws, suspends until bound
    let port = address.ipv4!.port                       // Int
    // print handshake, then:
    try await group.next()
}
```

`transport.listeningAddress` is an `async throws` property that suspends until the transport is actually listening. `SocketAddress.ipv4` returns `SocketAddress.IPv4?` with `.host: String` and `.port: Int`.

**Client transport + RPC calls**:
```swift
try await withGRPCClient(
    transport: try .http2NIOPosix(
        target: .ipv4(host: "127.0.0.1", port: port),
        transportSecurity: .plaintext
    )
) { client in
    let echo = Spike_V1_Echo.Client(wrapping: client)

    // Unary — default onResponse returns try response.message (the message object)
    let resp: Spike_V1_EchoResponse = try await echo.unaryEcho(
        .with { $0.message = "hello"; $0.count = 1 }
    )

    // Streaming — onResponse closure receives StreamingClientResponse
    let count = try await echo.streamEcho(
        .with { $0.message = "stream"; $0.count = 5 }
    ) { stream -> Int in
        var n = 0
        for try await _ in stream.messages { n += 1 }
        return n
    }
}
```

`http2NIOPosix` is a **throwing** (not async) static factory on `ClientTransport where Self == HTTP2ClientTransport.Posix`.

---

## Resolved dependency versions (Package.resolved)

| Package | Version |
|---|---|
| grpc-swift | **2.2.3** |
| grpc-swift-nio-transport | **1.2.3** |
| grpc-swift-protobuf | **1.3.1** |
| swift-protobuf | **1.38.0** |
| swift-nio | **2.101.0** |
| swift-nio-http2 | 1.44.0 |
| swift-nio-ssl | 2.37.1 |
| swift-nio-transport-services | 1.28.0 |
| swift-crypto | 4.5.0 |
| swift-certificates | 1.19.1 |
| swift-log | 1.13.2 |

---

## Results matrix

| Question | ubuntu-latest | macos-15 | windows-2022 | Notes |
|---|---|---|---|---|
| Q1 build (`swift build`) | ✅ | ✅ | ❌ | Windows: grpc-swift 2.2.3 missing `ucrt` import |
| Q2 unary RPC | ✅ | ✅ | ❌ | blocked by Q1 |
| Q3 server-streaming RPC | ✅ | ✅ | ❌ | blocked by Q1 |
| Q4 stdout handshake + 2-process | ✅ | ✅ | ❌ | blocked by Q1 |
| Q5 codegen on Windows (info) | n/a | n/a | not reached | allowed to fail |

Ubuntu and macOS output (confirming Q2–Q4):
```
server=.build/debug/SpikeServer client=.build/debug/SpikeClient
[server] {"event":"listening","port":49205,"pid":28094}
HANDSHAKE_OK port=49205 (Q4 pass)
UNARY_OK echo: hello
STREAM_OK 5
CLIENT_DONE
ALL_OK: Q2+Q3+Q4 passed
```

---

## Windows Q1 failure — exact diagnosis

**File:** `.build/checkouts/grpc-swift/Sources/GRPCCore/Call/Client/Internal/RetryDelaySequence.swift`

**Line 16–26:**
```swift
#if canImport(Darwin)
public import Darwin
#elseif canImport(Android)
public import Android
#elseif canImport(Glibc)
public import Glibc
#elseif canImport(Musl)
public import Musl
#else
#error("Unsupported OS")   // ← Windows hits this; pow() unavailable
#endif
```

Windows should use `ucrt` (Swift's C standard library shim on Windows, which provides `pow()`). The fix is:

```swift
#elseif canImport(ucrt)
public import ucrt
```

This is the **only** `#error("Unsupported OS")` in all of `GRPCCore`. Every other source file in grpc-swift 2.2.3 compiled on Windows without issue.

This is not a fundamental architectural problem — it is a one-file, one-line upstream bug in grpc-swift 2.2.3. The Windows gRPC runtime behavior (NIO TCP, HTTP/2 framing, protobuf serialization) was never reached; we cannot conclude it would or wouldn't work, only that it never compiled.

---

## Decision (per spike plan §8)

**Q1 fails on Windows**, but the cause is a missing `ucrt` import in one grpc-swift file, not a gRPC/NIO/Windows incompatibility. Recommended path forward (in order):

1. **File a PR to grpc-swift** adding `#elseif canImport(ucrt) / public import ucrt` to `RetryDelaySequence.swift`. If merged and released (grpc-swift 2.2.4+), re-run this spike — there are no other known blockers.

2. **Vendor-patch as a local override** while the upstream PR is in review: add a `Package.swift` local override or fork grpc-swift with the one-line fix to unblock the daemon work immediately.

3. **Custom framing fallback** (only if upstream is unresponsive): length-prefixed protobuf over a raw swift-nio TCP server. swift-nio itself compiles cleanly on Windows. This reuses all the protobuf message definitions; only the transport changes.

4. **macOS/Linux only**: Defer the Windows daemon. Not recommended given how trivial the fix is.

---

## Notes for the follow-on implementation agent

- The `@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)` annotation on the generated service protocols must be mirrored on conforming structs. On Linux/Windows it has no runtime effect; on macOS it's satisfied by the `platforms: [.macOS("15.0")]` deployment target in `Package.swift`.

- `Package.swift` must use `.macOS("15.0")` (string form), not `.macOS(.v15)` (enum form). The enum case `.v15` does not exist in the `PackageDescription` API bundled with Swift 6.0/6.1 on CI toolchains.

- `InProcessTransport` (from `GRPCInProcessTransport` module) is **deprecated** in grpc-swift 2.2.3 with a note pointing to https://forums.swift.org/t/80177. Use real loopback transport (port 0) for tests instead.

- The stdout flush for the port handshake is done via `FileHandle.standardOutput.write(Data((line + "\n").utf8))` — bypasses Swift's buffered `print()` to ensure the Python harness reads it immediately via the pipe.

- `ProcessInfo.processInfo.processIdentifier` is the cross-platform way to get the PID (not `getpid()`).
