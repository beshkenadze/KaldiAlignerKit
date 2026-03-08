#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-dev}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/.build/artifacts}"
KALDI_ROOT="${KALDI_ROOT:-$ROOT_DIR/.build/vendor/kaldi}"
SCHEME="KaldiAlignerKit"
FRAMEWORK_NAME="${SCHEME}.framework"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/${SCHEME}.xcframework"
ZIP_PATH="$ARTIFACTS_DIR/${SCHEME}-${VERSION}.xcframework.zip"
CHECKSUM_PATH="$ARTIFACTS_DIR/${SCHEME}-${VERSION}.checksum.txt"
NOTICES_PATH="$ARTIFACTS_DIR/${SCHEME}-${VERSION}.THIRD_PARTY_NOTICES.txt"
KALDI_LICENSE_PATH="$KALDI_ROOT/COPYING"
OPENFST_LICENSE_PATH="$KALDI_ROOT/tools/openfst-1.8.4/COPYING"
WORK_ROOT="$(mktemp -d "$ROOT_DIR/.build/release-work.XXXXXX")"
SOURCE_PACKAGE_DIR="$WORK_ROOT/package"
ARCHIVE_PATH="$WORK_ROOT/${SCHEME}.xcarchive"
DERIVED_DATA_PATH="$WORK_ROOT/DerivedData"

cleanup() {
  rm -rf "$WORK_ROOT"
}

trap cleanup EXIT

mkdir -p "$ARTIFACTS_DIR"
"$ROOT_DIR/scripts/build-kaldi.sh" "$KALDI_ROOT"

rm -rf "$XCFRAMEWORK_PATH"
mkdir -p "$SOURCE_PACKAGE_DIR"
cp -R "$ROOT_DIR/Sources" "$SOURCE_PACKAGE_DIR/Sources"
cp -R "$ROOT_DIR/Tests" "$SOURCE_PACKAGE_DIR/Tests"
cp "$ROOT_DIR/scripts/templates/Package.source.swift" "$SOURCE_PACKAGE_DIR/Package.swift"

pushd "$SOURCE_PACKAGE_DIR" >/dev/null
KALDI_ROOT="$KALDI_ROOT" xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  EXCLUDED_ARCHS=x86_64 \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
popd >/dev/null

FRAMEWORK_ARCHIVE_PATH="$(
  find "$ARCHIVE_PATH/Products" -type d -name "$FRAMEWORK_NAME" -print -quit
)"
SWIFTMODULE_PATH="$(
  find "$DERIVED_DATA_PATH/Build" -type d -path "*/BuildProductsPath/Release/${SCHEME}.swiftmodule" -print -quit
)"
SWIFT_HEADER_PATH="$(
  find "$DERIVED_DATA_PATH/Build" -type f -path "*/GeneratedModuleMaps/${SCHEME}-Swift.h" -print -quit
)"

if [[ -z "$FRAMEWORK_ARCHIVE_PATH" ]]; then
  echo "Could not locate $FRAMEWORK_NAME inside $ARCHIVE_PATH" >&2
  exit 1
fi

if [[ -z "$SWIFTMODULE_PATH" || -z "$SWIFT_HEADER_PATH" ]]; then
  echo "Could not locate Swift module metadata for $SCHEME" >&2
  exit 1
fi

FRAMEWORK_VERSION_PATH="$FRAMEWORK_ARCHIVE_PATH/Versions/A"
FRAMEWORK_HEADERS_PATH="$FRAMEWORK_VERSION_PATH/Headers"
FRAMEWORK_MODULES_PATH="$FRAMEWORK_VERSION_PATH/Modules"
FRAMEWORK_SWIFTMODULE_DEST="$FRAMEWORK_MODULES_PATH/${SCHEME}.swiftmodule"
FRAMEWORK_ROOT_HEADERS_PATH="$FRAMEWORK_ARCHIVE_PATH/Headers"
FRAMEWORK_ROOT_MODULES_PATH="$FRAMEWORK_ARCHIVE_PATH/Modules"

mkdir -p "$FRAMEWORK_HEADERS_PATH" "$FRAMEWORK_SWIFTMODULE_DEST"
cp -R "$SWIFTMODULE_PATH"/. "$FRAMEWORK_SWIFTMODULE_DEST/"
cp "$SWIFT_HEADER_PATH" "$FRAMEWORK_HEADERS_PATH/${SCHEME}-Swift.h"
cat > "$FRAMEWORK_MODULES_PATH/module.modulemap" <<EOF
framework module ${SCHEME} {
  umbrella header "${SCHEME}-Swift.h"

  export *
  module * { export * }
}
EOF

rm -rf "$FRAMEWORK_ROOT_HEADERS_PATH" "$FRAMEWORK_ROOT_MODULES_PATH"
cp -R "$FRAMEWORK_HEADERS_PATH" "$FRAMEWORK_ROOT_HEADERS_PATH"
cp -R "$FRAMEWORK_MODULES_PATH" "$FRAMEWORK_ROOT_MODULES_PATH"

xcodebuild -create-xcframework \
  -framework "$FRAMEWORK_ARCHIVE_PATH" \
  -output "$XCFRAMEWORK_PATH"

rm -f "$ZIP_PATH"
(
  cd "$ARTIFACTS_DIR"
  zip -qry --symlinks "$(basename "$ZIP_PATH")" "$(basename "$XCFRAMEWORK_PATH")"
)
swift package compute-checksum "$ZIP_PATH" | tee "$CHECKSUM_PATH"

cat > "$NOTICES_PATH" <<EOF
KaldiAlignerKit bundles build outputs from the following upstream projects:

- Kaldi: https://github.com/kaldi-asr/kaldi
- OpenFST 1.8.4: https://www.openfst.org/

This artifact was produced on $(date -u +"%Y-%m-%dT%H:%M:%SZ") for version $VERSION.
Bundled notice sources:
- ${KALDI_LICENSE_PATH}
- ${OPENFST_LICENSE_PATH}
EOF

if [[ -f "$KALDI_LICENSE_PATH" ]]; then
  {
    printf '\n===== Kaldi License (%s) =====\n\n' "$KALDI_LICENSE_PATH"
    cat "$KALDI_LICENSE_PATH"
  } >> "$NOTICES_PATH"
fi

if [[ -f "$OPENFST_LICENSE_PATH" ]]; then
  {
    printf '\n\n===== OpenFST License (%s) =====\n\n' "$OPENFST_LICENSE_PATH"
    cat "$OPENFST_LICENSE_PATH"
  } >> "$NOTICES_PATH"
fi
