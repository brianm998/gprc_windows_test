#!/usr/bin/env python3
import json, subprocess, sys, time, os, threading

# Locate built binaries (Windows adds .exe).
exe = ".exe" if os.name == "nt" else ""
build_dir = os.path.join(".build", "debug")
server_bin = os.path.join(build_dir, "SpikeServer" + exe)
client_bin = os.path.join(build_dir, "SpikeClient" + exe)

print(f"server={server_bin} client={client_bin}", flush=True)

# Launch server, capture stdout, find the handshake line.
server = subprocess.Popen([server_bin], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, bufsize=1)

port = None
deadline = time.time() + 60

def read_lines():
    global port
    for line in server.stdout:
        sys.stdout.write("[server] " + line); sys.stdout.flush()
        line = line.strip()
        if line.startswith("{") and '"event"' in line and '"listening"' in line:
            try:
                port = json.loads(line)["port"]
            except Exception as e:
                print("handshake parse error:", e)

t = threading.Thread(target=read_lines, daemon=True); t.start()
while port is None and time.time() < deadline and server.poll() is None:
    time.sleep(0.2)

if port is None:
    print("FAIL: never received listening handshake (Q4)"); server.kill(); sys.exit(10)
print(f"HANDSHAKE_OK port={port} (Q4 pass)", flush=True)

# Run the client against the discovered port.
res = subprocess.run([client_bin, str(port)], text=True, capture_output=True, timeout=60)
sys.stdout.write(res.stdout); sys.stderr.write(res.stderr)

server.terminate()
try: server.wait(timeout=10)
except Exception: server.kill()

if res.returncode != 0:
    print(f"FAIL: client exit {res.returncode} (Q2/Q3)"); sys.exit(res.returncode)
if "UNARY_OK" not in res.stdout: print("FAIL: no UNARY_OK (Q2)"); sys.exit(11)
if "STREAM_OK" not in res.stdout: print("FAIL: no STREAM_OK (Q3)"); sys.exit(12)
print("ALL_OK: Q2+Q3+Q4 passed")
