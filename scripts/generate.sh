#!/usr/bin/env bash
set -euo pipefail
# Requires protoc + the swift plugins. Build the plugins from the resolved packages, or install:
#   brew install protobuf swift-protobuf            # provides protoc-gen-swift
# and build protoc-gen-grpc-swift from grpc-swift-protobuf (or install from the grpc-swift releases).
protoc \
  --proto_path=proto \
  --swift_out=Visibility=Public:Sources/SpikeProto \
  --grpc-swift_out=Visibility=Public:Sources/SpikeProto \
  proto/spike.proto
echo "Generated stubs into Sources/SpikeProto — commit them."
