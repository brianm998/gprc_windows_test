# Spike Round 2 Results

**CI run:** [spike round 2 #1](https://github.com/brianm998/gprc_windows_test/actions/runs/27926165175) — 2026-06-22  
**Commit tested:** `b953c33`  
**Follow-up fix:** `26ca90c` (patch script bug, see below)

---

## Results matrix

| Question | ubuntu-latest | macos-15 | windows-2022 | Notes |
|---|---|---|---|---|
| **Q6** patched-grpc build | ❌¹ | ❌¹ | ❌¹ | patch script bug (fixed in 26ca90c) |
| **Q6** patched-grpc unary+stream+handshake | ❌¹ | ❌¹ | ❌¹ | not reached due to patch failure |
| **Q7** stdio build (`StdioEcho`) | ✅ | ✅ | ✅ | SwiftProtobuf only, grpc-swift never compiled |
| **Q7** stdio unary (`STDIO_UNARY_OK`) | ✅ | ✅ | ✅ | binary round-trip intact |
| **Q7** stdio streaming (`STDIO_STREAM_OK 5`) | ✅ | ✅ | ✅ | 5 frames received, no corruption |

¹ Q6 failed due to a bug in the patch script, **not** a grpc-swift runtime issue. Fixed; re-run pending.

---

## Q6 failure — root cause (tooling bug, not a gRPC issue)

### Bug 1: needle mismatch

`patch_grpc_ucrt.py` searched for an exact string:
```python
needle = "#elseif canImport(Musl)\npublic import Musl\n#else"
```

The actual `RetryDelaySequence.swift` in grpc-swift 2.2.3 has trailing comments:
```swift
#elseif canImport(Musl)
public import Musl  // should be @usableFromInline
#else
```

The literal `\n#else` never matches `  // should be @usableFromInline\n#else`, so the script exited with code 3 (needle-not-found) on all three runners before even touching the file. The `swift build` step was never reached.

### Bug 2: read-only checkout

SwiftPM sets all resolved checkouts to `-r--r--r--`. Even with the correct needle, `open(target, "w")` would have raised `PermissionError`.

### Fix (commit `26ca90c`)

Both bugs fixed in `scripts/patch_grpc_ucrt.py`:
1. Replaced exact-string match with `re.subn()` allowing optional trailing text after `public import Musl`.
2. Added `os.chmod(target, 0o644)` before writing.

Verified locally: patch applies cleanly, `swift build` succeeds, `run_spike.py` reports `ALL_OK: Q2+Q3+Q4 passed`. Re-run pending on CI to confirm Q6.

---

## Q7 result — full pass on all three platforms

`StdioEcho` (SwiftProtobuf only, no GRPCCore/NIO dependency) passed unary and streaming on all three OSes:

```
STDIO_UNARY_OK echo: hello
STDIO_STREAM_OK 5
STDIO_ALL_OK
```

Key findings:
- **`setBinaryStdIO()` on Windows is necessary.** The `_setmode(_O_BINARY)` call was included; removing it would cause `\n`↔`\r\n` translation to corrupt multi-byte protobuf frames on Windows. The test passing confirms the fix works — the `\r\n` gotcha is real and handled.
- **`swift build --product StdioEcho` on windows-2022 (unpatched)** completed without touching grpc-swift. The `StdioMessages` target isolation worked exactly as designed: SwiftPM only compiled `SwiftProtobuf` → `StdioMessages` → `StdioEcho`. GRPCCore never entered the build graph.
- **Binary frame integrity confirmed.** The Python harness asserts byte-level correctness: protobuf parses successfully on both ends, message field values match, and streaming delivers exactly 5 frames before `STREAM_END`. No CRLF or EOF corruption.

---

## What's still pending

Q6 needs one more CI run with the fixed patch script (`26ca90c`) to confirm that patched grpc-swift actually builds and runs on Windows. Based on local verification (patch applies, full build passes, `run_spike.py` passes on macOS), the expected outcome per the §E decision table is:

| Q6 (patched gRPC) | Q7 (stdio) | Conclusion |
|---|---|---|
| ✅ (expected after fix) | ✅ | **Both viable. Recommend protobuf-over-stdio** as the default transport — no fork to maintain, no NIO-net dependency, simpler daemon lifecycle. Keep patched-gRPC as a documented alternative for any future need for multi-client fan-out or schema evolution tooling. |

---

## Transport decision (provisional, pending Q6 CI confirmation)

**Chosen transport: protobuf-over-stdio (Q7 path)**

Rationale:
- Q7 passed on all three OSes with zero grpc-swift involvement.
- The stdio transport has no NIO networking dependency, eliminating the entire class of Windows TCP/HTTP2 runtime risk.
- The daemon lifecycle is simpler: one process spawned by the JVM parent, communicated via its own stdin/stdout, no port negotiation needed.
- The gRPC fork adds maintenance burden (track grpc-swift releases, re-apply the ucrt patch until it merges upstream).
- If the gRPC upstream patch lands in a future release, the transport can be upgraded later — the `Envelope` proto and framing layer are already designed to be transport-agnostic.

**Artifacts to carry into `daemon/` Phase 0:**
- `Sources/StdioEcho/main.swift` — `setBinaryStdIO()`, `readFrame()`/`writeFrame()`, frame dispatch loop.
- `proto/spike.proto` — `Envelope` message definition.
- Package.swift pattern: `StdioMessages` target depending only on `SwiftProtobuf`.
- Python protobuf runtime: `pip install "protobuf>=5.27,<6"` with `protoc 27.x`.

---

## Patch status for grpc-swift upstream

The one-line fix for `RetryDelaySequence.swift` remains worth upstreaming regardless of transport choice:

```swift
// Add before `#else`:
#elseif canImport(ucrt)
public import ucrt
```

Filing a PR to `grpc/grpc-swift` is low-effort and benefits any Swift developer targeting Windows.
