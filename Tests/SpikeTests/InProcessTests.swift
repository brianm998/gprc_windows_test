import XCTest
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto

// Minimal in-process sanity test: starts a real loopback server in a background task,
// connects a client, and runs both RPCs. This is not the CI gate (that's run_spike.py);
// it's a fast build-and-basic-run check. continue-on-error in CI.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class InProcessTests: XCTestCase {

    func testUnaryAndStreamOverLoopback() async throws {
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [LocalEchoService()])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }

            let address = try await transport.listeningAddress
            guard let port = address.ipv4?.port else {
                XCTFail("Could not get bound port")
                return
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
                    .with { $0.message = "test"; $0.count = 1 }
                )
                XCTAssertEqual(resp.message, "echo: test")

                // Q3: server-streaming
                let count = try await echo.streamEcho(
                    .with { $0.message = "tick"; $0.count = 3 }
                ) { stream -> Int in
                    var n = 0
                    for try await _ in stream.messages { n += 1 }
                    return n
                }
                XCTAssertEqual(count, 3)
            }

            group.cancelAll()
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct LocalEchoService: Spike_V1_Echo.SimpleServiceProtocol {
    func unaryEcho(
        request: Spike_V1_EchoRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Spike_V1_EchoResponse {
        .with { $0.message = "echo: \(request.message)"; $0.index = 0 }
    }

    func streamEcho(
        request: Spike_V1_EchoRequest,
        response: GRPCCore.RPCWriter<Spike_V1_EchoResponse>,
        context: GRPCCore.ServerContext
    ) async throws {
        for i in 0..<max(1, request.count) {
            try await response.write(
                .with { $0.message = "echo: \(request.message)"; $0.index = i }
            )
        }
    }
}
