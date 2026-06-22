# grpc-swift Windows Spike

Validates that **grpc-swift 2** can build and run on **Windows** (and Linux/macOS) via GitHub Actions.
A throwaway spike — the result informs whether the headless Swift daemon approach in
`CROSS_PLATFORM_DAEMON_DESIGN.md` is viable on Windows.

See `GRPC_WINDOWS_SPIKE_PLAN.md` for full background, methodology, and decision tree.

---

## Questions being tested (each is pass/fail per OS)

| # | Question | How tested |
|---|---|---|
| Q1 | Does grpc-swift 2 resolve and compile on Windows? | `swift build` CI job |
| Q2 | Can a server bind an ephemeral loopback port and a client complete a **unary** RPC? | `scripts/run_spike.py` |
| Q3 | Does a **server-streaming** RPC work? | `scripts/run_spike.py` |
| Q4 | Does the stdout port-handshake pattern work on Windows? | `scripts/run_spike.py` |
| Q5 | Does `protoc` codegen work on Windows? (informational, non-blocking) | `codegen-windows` CI job |

---

## Results matrix

| Question | ubuntu | macos | windows | Notes |
|---|---|---|---|---|
| Q1 build (`swift build`) | ✅ | ✅ | ❌ | Windows: grpc-swift 2.2.3 missing `ucrt` import — see below |
| Q2 unary RPC | ✅ | ✅ | ❌ | blocked by Q1 |
| Q3 server-streaming RPC | ✅ | ✅ | ❌ | blocked by Q1 |
| Q4 stdout handshake + 2-process | ✅ | ✅ | ❌ | blocked by Q1 |
| Q5 codegen on Windows (info) | n/a | n/a | ? | allowed to fail |

### Windows Q1 failure — diagnosis

`GRPCCore/Call/Client/Internal/RetryDelaySequence.swift` uses `pow()` and imports it via platform guards:

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
#error("Unsupported OS")   // ← Windows hits this
#endif
```

Windows should import `ucrt` (Swift's C standard library shim on Windows). The fix is a one-liner in grpc-swift upstream:

```swift
#elseif canImport(ucrt)
public import ucrt
```

This is the **only** `#error("Unsupported OS")` in GRPCCore. All other grpc-swift source compiles on Windows without issue.

### Decision (per §8 of the spike plan)

Q1 fails on Windows for grpc-swift 2.2.3. However the failure is a trivial one-file patch in grpc-swift, **not** a fundamental architectural limitation. Options in order of preference:

1. **Upstream the fix**: One-line PR to grpc-swift adding `#elseif canImport(ucrt)` in `RetryDelaySequence.swift`. If merged and released, grpc-swift is viable on Windows.
2. **Vendor-patch**: Fork or local override of grpc-swift with the fix while the upstream PR is reviewed.
3. **Custom framing fallback**: Length-prefixed protobuf over swift-nio TCP (swift-nio itself compiles on Windows without issue).
4. **macOS/Linux only**: Defer Windows daemon.

---

## Resolved versions

| Package | Version |
|---|---|
| grpc-swift | 2.2.3 |
| grpc-swift-nio-transport | 1.2.3 |
| grpc-swift-protobuf | 1.3.1 |
| swift-protobuf | 1.38.0 |
| swift-nio | 2.101.0 |

---

## Local smoke test (macOS/Linux)

```bash
swift build
python3 scripts/run_spike.py
# Expected: ALL_OK: Q2+Q3+Q4 passed
```

Verified locally on macOS (darwin 24.6.0, Swift 6.x):
- Q2 UNARY_OK ✓
- Q3 STREAM_OK 5 ✓
- Q4 HANDSHAKE_OK ✓

---

## Repo layout

```
Package.swift               grpc-swift 2 package manifest
proto/spike.proto           service definition (Echo: unary + server-streaming)
Sources/SpikeProto/         pre-generated stubs (committed — CI does not regenerate)
Sources/SpikeServer/        server binary: binds port 0, prints JSON handshake to stdout
Sources/SpikeClient/        client binary: reads port from argv[1], runs Q2+Q3, exits 0 on success
Tests/SpikeTests/           in-process loopback test (sanity, continue-on-error in CI)
scripts/run_spike.py        cross-platform harness: spawn server, read handshake, run client, assert
scripts/generate.sh         dev-only: regenerate stubs on macOS/Linux (not run in CI gate)
.github/workflows/spike.yml matrix: ubuntu-latest, macos-14, windows-latest
```

---

## Stub generation policy

Stubs (`spike.pb.swift`, `spike.grpc.swift`) are **pre-generated and committed**.
CI builds them directly — no `protoc` required in the main gate.
This ensures a Windows build failure points at the gRPC runtime, not at codegen tooling.

To regenerate (macOS/Linux with compatible `protoc-gen-grpc-swift` from resolved packages):

```bash
# Build protoc-gen-grpc-swift from the resolved grpc-swift-protobuf version:
cd .build/checkouts/grpc-swift-protobuf && swift build --product protoc-gen-grpc-swift && cd -
PLUGIN=.build/checkouts/grpc-swift-protobuf/.build/debug/protoc-gen-grpc-swift
protoc \
  --proto_path=proto \
  --plugin=protoc-gen-grpc-swift=$PLUGIN \
  --swift_out=Visibility=Public:Sources/SpikeProto \
  --grpc-swift_out=Visibility=Public:Sources/SpikeProto \
  proto/spike.proto
# Then commit the regenerated files.
```

Q5 (codegen on Windows) is tested in a separate `continue-on-error` CI job.

---

## Interpreting the outcome

- **All of Q1–Q4 green on Windows** → grpc-swift transport validated; proceed with daemon design as written.
- **Q1 fails (won't build)** → grpc-swift not viable on Windows. Fallback: custom length-prefixed protobuf over swift-nio TCP (spike swift-nio alone next), or macOS/Linux-only daemon.
- **Q1/Q2 pass but Q3 fails** → progress streaming would need polling; minor design change, not a blocker.
- **Q4 fails only** → handshake/process-spawn issue, not a gRPC issue; write port to a file instead of stdout.
- **Q5 fails** → generate stubs in CI on Linux/macOS and commit. Not a blocker.
