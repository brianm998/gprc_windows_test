import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@main
struct Client {
    static func main() async throws {
        guard CommandLine.arguments.count > 1, let port = Int(CommandLine.arguments[1]) else {
            FileHandle.standardError.write(Data("usage: SpikeClient <port>\n".utf8))
            exit(64)
        }

        try await withGRPCClient(
            transport: try .http2NIOPosix(
                target: .ipv4(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            )
        ) { client in
            let echo = Spike_V1_Echo.Client(wrapping: client)

            // Q2: unary
            let resp = try await echo.unaryEcho(
                .with { $0.message = "hello"; $0.count = 1 }
            )
            guard resp.message == "echo: hello" else {
                FileHandle.standardError.write(Data("unary mismatch: \(resp.message)\n".utf8))
                exit(3)
            }
            print("UNARY_OK \(resp.message)")

            // Q3: server-streaming
            let received = try await echo.streamEcho(
                .with { $0.message = "stream"; $0.count = 5 }
            ) { stream -> Int in
                var count = 0
                for try await _ in stream.messages { count += 1 }
                return count
            }
            guard received == 5 else {
                FileHandle.standardError.write(Data("stream count \(received) != 5\n".utf8))
                exit(4)
            }
            print("STREAM_OK \(received)")
        }
        print("CLIENT_DONE")
    }
}
