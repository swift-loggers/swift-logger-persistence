#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="${1:-}"
if [ -z "$PACKAGE_ROOT" ]; then
  PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [ ! -f "$PACKAGE_ROOT/Package.swift" ]; then
  echo "Package root does not contain Package.swift: $PACKAGE_ROOT" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-logger-persistence-consumer.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "Using package root: $PACKAGE_ROOT"
echo "Using work dir: $WORK_DIR"

mkdir -p "$WORK_DIR/Sources/SPMConsumerSmoke"

PACKAGE_ROOT_SWIFT="${PACKAGE_ROOT//\\/\\\\}"
PACKAGE_ROOT_SWIFT="${PACKAGE_ROOT_SWIFT//\"/\\\"}"

cat > "$WORK_DIR/Package.swift" <<SWIFT
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-persistence-consumer-smoke",
    platforms: [
        .iOS("13.4"),
        .tvOS("13.4"),
        .macOS("10.15.4"),
        .watchOS("6.2"),
        .visionOS(.v1)
    ],
    dependencies: [
        .package(path: "$PACKAGE_ROOT_SWIFT")
    ],
    targets: [
        .executableTarget(
            name: "SPMConsumerSmoke",
            dependencies: [
                .product(name: "LoggerPersistence", package: "swift-logger-persistence"),
                .product(name: "LoggerFilePersistence", package: "swift-logger-persistence")
            ]
        )
    ]
)
SWIFT

cat > "$WORK_DIR/Sources/SPMConsumerSmoke/SPMConsumerSmoke.swift" <<'SWIFT'
import Foundation
import LoggerFilePersistence
import LoggerPersistence

@main
struct SPMConsumerSmoke {
    static func main() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rotation = try RotationPolicy.bySize(
            maxSegmentBytes: FileLogStore.maxEncodedLineBytes
        )
        let retention = try RetentionPolicy.maxSegments(4)
        let store = FileLogStore(
            configuration: .init(
                directory: directory,
                rotation: rotation,
                retention: retention
            )
        )

        let envelope = try PersistentLogEnvelope(
            id: UUID(),
            sequence: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentType: "application/vnd.swift-loggers.smoke+json",
            hints: [:],
            payload: Data(#"{"message":"spm-smoke"}"#.utf8)
        )

        try await store.append(envelope)
        try await store.flush()
    }
}
SWIFT

swift --version

swift run \
  --package-path "$WORK_DIR" \
  --scratch-path "$WORK_DIR/.build" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  SPMConsumerSmoke
