#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${1:-$ROOT_DIR/.build/vendor/kaldi}"
OPENFST_VERSION="${OPENFST_VERSION:-1.8.4}"
OPENFST_ARCHIVE_NAME="openfst-${OPENFST_VERSION}.tar.gz"
OPENFST_RELEASE_URL="${OPENFST_RELEASE_URL:-https://github.com/beshkenadze/KaldiAlignerKit/releases/download/openfst-${OPENFST_VERSION}/${OPENFST_ARCHIVE_NAME}}"
OPENFST_SHA256="${OPENFST_SHA256:-}"

mkdir -p "$PREFIX"

if [[ -f "$PREFIX/src/base/libkaldi-base.a" && -f "$PREFIX/tools/openfst/lib/libfst.a" ]]; then
  echo "Kaldi already present at $PREFIX"
  echo "export KALDI_ROOT=$PREFIX"
  exit 0
fi

BUILD_ROOT="$ROOT_DIR/.build/vendor"
KALDI_REPO="$BUILD_ROOT/kaldi-src"
mkdir -p "$BUILD_ROOT"

if [[ ! -d "$KALDI_REPO/.git" ]]; then
  git clone --depth 1 https://github.com/kaldi-asr/kaldi.git "$KALDI_REPO"
fi

pushd "$KALDI_REPO/tools" >/dev/null
curl -fL "$OPENFST_RELEASE_URL" -o "$OPENFST_ARCHIVE_NAME"
if [[ -n "$OPENFST_SHA256" ]]; then
  echo "$OPENFST_SHA256  $OPENFST_ARCHIVE_NAME" | shasum -a 256 -c -
fi
rm -rf "openfst-${OPENFST_VERSION}" openfst
tar xf "$OPENFST_ARCHIVE_NAME"
pushd "openfst-${OPENFST_VERSION}" >/dev/null
CXXFLAGS="-O3 -fPIC -arch arm64" ./configure \
  --enable-static --disable-shared \
  --enable-far --enable-ngram-fsts \
  --enable-lookahead-fsts --with-pic \
  --prefix="$KALDI_REPO/tools/openfst"
make -j"$(sysctl -n hw.ncpu)"
make install
popd >/dev/null
popd >/dev/null

pushd "$KALDI_REPO/src" >/dev/null
./configure --static --static-fst --fst-root="$KALDI_REPO/tools/openfst" --fst-version="$OPENFST_VERSION"
CXXFLAGS="-O3 -fPIC -arch arm64" make -j"$(sysctl -n hw.ncpu)" \
  base matrix util feat tree gmm hmm transform fstext decoder lat lm
find "$KALDI_REPO/src" -maxdepth 2 -name 'kaldi-*.a' | while IFS= read -r archive; do
  ln -sf "$archive" "$(dirname "$archive")/lib$(basename "$archive")"
done
popd >/dev/null

rm -rf "$PREFIX"
mkdir -p "$(dirname "$PREFIX")"
cp -R "$KALDI_REPO" "$PREFIX"

echo "Built Kaldi into $PREFIX"
echo "export KALDI_ROOT=$PREFIX"
