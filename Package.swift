// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrpcWindowsSpike",
    platforms: [.macOS(.v15)],   // ignored on Windows/Linux; grpc-swift 2 needs macOS 15 when on mac
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git",               from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git",      from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git",          from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "SpikeProto",
            dependencies: [
                .product(name: "GRPCCore",      package: "grpc-swift"),
                .product(name: "GRPCProtobuf",  package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "SpikeServer",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",               package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
        .executableTarget(
            name: "SpikeClient",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",               package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
        .testTarget(
            name: "SpikeTests",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",               package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
    ]
)
