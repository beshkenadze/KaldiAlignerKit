#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_PATH="${1:-$ROOT_DIR/.build/artifacts/KaldiAlignerKit.xcframework}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/binary-smoke}"
PACKAGE_DIR="$WORK_DIR/package"
CLIENT_DIR="$WORK_DIR/client"

if [[ ! -d "$ARTIFACT_PATH" ]]; then
  echo "xcframework not found at $ARTIFACT_PATH" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$PACKAGE_DIR" "$CLIENT_DIR/Sources/BinarySmoke"
cp -R "$ARTIFACT_PATH" "$PACKAGE_DIR/KaldiAlignerKit.xcframework"
"$ROOT_DIR/scripts/render-package-manifest.sh" \
  binary-path \
  KaldiAlignerKit.xcframework \
  "$PACKAGE_DIR/Package.swift"

cat > "$CLIENT_DIR/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BinarySmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../package"),
    ],
    targets: [
        .executableTarget(
            name: "BinarySmoke",
            dependencies: [
                .product(name: "KaldiAlignerKit", package: "package"),
            ]
        ),
    ]
)
EOF

cat > "$CLIENT_DIR/Sources/BinarySmoke/main.swift" <<'EOF'
import KaldiAlignerKit

let paths = MFAModelPaths(modelDir: "/tmp/model", dictPath: "/tmp/dict")
print(paths.modelDir)
print(WordAlignment.self)
print(KaldiAligner.self)
EOF

swift build --package-path "$CLIENT_DIR"
