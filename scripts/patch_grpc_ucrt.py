#!/usr/bin/env python3
"""Insert the missing ucrt import into grpc-swift's RetryDelaySequence.swift in the resolved checkout.
Idempotent; safe to run before `swift build`. Must run AFTER `swift package resolve`."""
import os, sys

target = os.path.join(".build", "checkouts", "grpc-swift",
                      "Sources", "GRPCCore", "Call", "Client", "Internal",
                      "RetryDelaySequence.swift")

if not os.path.exists(target):
    print(f"FAIL: {target} not found — did `swift package resolve` run?")
    sys.exit(2)

src = open(target, encoding="utf-8").read()

if "canImport(ucrt)" in src:
    print("already patched")
    sys.exit(0)

needle = "#elseif canImport(Musl)\npublic import Musl\n#else"
repl   = "#elseif canImport(Musl)\npublic import Musl\n#elseif canImport(ucrt)\npublic import ucrt\n#else"

if needle not in src:
    print("WARN: exact needle not found; dumping the import block for manual inspection:")
    import re
    m = re.search(r"#if canImport\(Darwin\).*?#endif", src, re.S)
    print(m.group(0) if m else "(import block not found)")
    sys.exit(3)

open(target, "w", encoding="utf-8").write(src.replace(needle, repl))
print(f"patched {target}")
