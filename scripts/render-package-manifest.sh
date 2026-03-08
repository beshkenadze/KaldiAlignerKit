#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

case "$MODE" in
  source)
    OUTPUT_PATH="${2:-$ROOT_DIR/Package.swift}"
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    cp "$ROOT_DIR/scripts/templates/Package.source.swift" "$OUTPUT_PATH"
    ;;
  binary)
    ARTIFACT_URL="${2:-}"
    ARTIFACT_CHECKSUM="${3:-}"
    OUTPUT_PATH="${4:-$ROOT_DIR/Package.swift}"
    if [[ -z "$ARTIFACT_URL" || -z "$ARTIFACT_CHECKSUM" ]]; then
      echo "usage: $0 binary <artifact-url> <checksum> [output-path]" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    sed \
      -e "s|__ARTIFACT_URL__|$ARTIFACT_URL|g" \
      -e "s|__ARTIFACT_CHECKSUM__|$ARTIFACT_CHECKSUM|g" \
      "$ROOT_DIR/scripts/templates/Package.binary.swift" > "$OUTPUT_PATH"
    ;;
  binary-path)
    ARTIFACT_PATH="${2:-}"
    OUTPUT_PATH="${3:-$ROOT_DIR/Package.swift}"
    if [[ -z "$ARTIFACT_PATH" ]]; then
      echo "usage: $0 binary-path <artifact-path> [output-path]" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    sed \
      -e "s|__ARTIFACT_PATH__|$ARTIFACT_PATH|g" \
      "$ROOT_DIR/scripts/templates/Package.binary.local.swift" > "$OUTPUT_PATH"
    ;;
  *)
    echo "usage: $0 <source|binary|binary-path> [...]" >&2
    exit 1
    ;;
esac
