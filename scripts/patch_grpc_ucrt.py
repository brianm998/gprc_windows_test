#!/usr/bin/env python3
"""Insert the missing ucrt import into grpc-swift's RetryDelaySequence.swift in the resolved checkout.
Idempotent; safe to run before `swift build`. Must run AFTER `swift package resolve`."""
import os, re, sys

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

# Match `#elseif canImport(Musl)\npublic import Musl<optional trailing comment>\n#else`
# so the patch is robust to grpc-swift adding/removing trailing // comments.
pattern = r"(#elseif canImport\(Musl\)\npublic import Musl[^\n]*\n)(#else)"
repl    = r"\1#elseif canImport(ucrt)\npublic import ucrt\n\2"

new_src, count = re.subn(pattern, repl, src)
if count == 0:
    print("WARN: pattern not found; dumping the import block for manual inspection:")
    m = re.search(r"#if canImport\(Darwin\).*?#endif", src, re.S)
    print(m.group(0) if m else "(import block not found)")
    sys.exit(3)

os.chmod(target, 0o644)   # SwiftPM checkouts are read-only; make writable before patching
open(target, "w", encoding="utf-8").write(new_src)
print(f"patched {target} ({count} substitution)")
