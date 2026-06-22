import Foundation
import StdioMessages
import SwiftProtobuf
#if os(Windows)
import ucrt
#endif

// Windows opens stdio in text mode by default: \n<->\r\n translation and 0x1A=EOF corrupt binary protobuf.
func setBinaryStdIO() {
#if os(Windows)
    let O_BINARY: Int32 = 0x8000
    _ = _setmode(_fileno(stdin),  O_BINARY)
    _ = _setmode(_fileno(stdout), O_BINARY)
#endif
}

let inHandle  = FileHandle.standardInput
let outHandle = FileHandle.standardOutput
func logErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func readExactly(_ n: Int) -> Data? {
    var buf = Data()
    while buf.count < n {
        let chunk = inHandle.readData(ofLength: n - buf.count)
        if chunk.isEmpty { return nil }
        buf.append(chunk)
    }
    return buf
}

func readFrame() -> Data? {
    guard let hdr = readExactly(4) else { return nil }
    let n = hdr.reduce(0) { ($0 << 8) | Int($1) }   // 4-byte big-endian length prefix
    return readExactly(n)
}

func writeFrame(_ data: Data) {
    let n = UInt32(data.count).bigEndian
    var header = Data(count: 4)
    withUnsafeBytes(of: n) { header.replaceSubrange(0..<4, with: $0) }
    outHandle.write(header)
    outHandle.write(data)   // FileHandle.write is unbuffered on all platforms
}

func makeEnvelope(id: UInt64, kind: Spike_V1_Envelope.Kind,
                  payload: Data = Data(), error: String = "") -> Data {
    var e = Spike_V1_Envelope()
    e.id = id; e.kind = kind; e.payload = payload; e.error = error
    return (try? e.serializedData()) ?? Data()
}

setBinaryStdIO()
logErr("StdioEcho up (pid \(ProcessInfo.processInfo.processIdentifier))")

while let frame = readFrame() {
    guard let env = try? Spike_V1_Envelope(serializedBytes: frame) else {
        logErr("bad envelope frame"); continue
    }
    let req = try? Spike_V1_EchoRequest(serializedBytes: env.payload)
    switch env.method {
    case "echo":
        var r = Spike_V1_EchoResponse()
        r.message = "echo: \(req?.message ?? "")"
        r.index = 0
        writeFrame(makeEnvelope(id: env.id, kind: .response,
                                payload: (try? r.serializedData()) ?? Data()))
    case "stream":
        let count = max(1, Int(req?.count ?? 1))
        for i in 0..<count {
            var item = Spike_V1_EchoResponse()
            item.message = "echo: \(req?.message ?? "")"
            item.index = Int32(i)
            writeFrame(makeEnvelope(id: env.id, kind: .streamItem,
                                    payload: (try? item.serializedData()) ?? Data()))
        }
        writeFrame(makeEnvelope(id: env.id, kind: .streamEnd))
    case "shutdown":
        logErr("shutdown requested"); exit(0)
    default:
        writeFrame(makeEnvelope(id: env.id, kind: .error, error: "unknown method \(env.method)"))
    }
}
logErr("stdin closed, exiting")
