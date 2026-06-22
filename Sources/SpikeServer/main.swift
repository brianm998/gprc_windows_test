import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct EchoService: Spike_V1_Echo.SimpleServiceProtocol {
    func unaryEcho(
        request: Spike_V1_EchoRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Spike_V1_EchoResponse {
        return .with { $0.message = "echo: \(request.message)"; $0.index = 0 }
    }

    func streamEcho(
        request: Spike_V1_EchoRequest,
        response: GRPCCore.RPCWriter<Spike_V1_EchoResponse>,
        context: GRPCCore.ServerContext
    ) async throws {
        let n = max(1, request.count)
        for i in 0..<n {
            try await response.write(
                .with { $0.message = "echo: \(request.message)"; $0.index = i }
            )
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@main
struct Server {
    static func main() async throws {
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [EchoService()])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }

            let address = try await transport.listeningAddress
            guard let port = address.ipv4?.port else {
                FileHandle.standardError.write(Data("failed to get IPv4 listening address\n".utf8))
                exit(2)
            }
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            let line = #"{"event":"listening","port":\#(port),"pid":\#(pid)}"#
            // Write directly to the file descriptor to bypass Swift's buffering.
            FileHandle.standardOutput.write(Data((line + "\n").utf8))

            try await group.next()
        }
    }
}
