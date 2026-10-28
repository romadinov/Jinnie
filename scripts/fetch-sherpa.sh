#!/bin/bash
# Fetches sherpa-onnx (official static macOS arm64 build, speech recognition only) into Vendor/sherpa-onnx, for GigaAM
# Russian transcription. Pinned version and SHA-256; runs before every Mac build and does nothing once in place.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="v2.0.1"
LIB_SHA="69413605e7d0d1286d40fbf66e898f7abb53f350d6057cbd154ea2e3f1437d2a"
HEADER_SHA="5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f"
DEST="Vendor/sherpa-onnx"
STAMP="$DEST/.version-$VERSION"
[ -f "$STAMP" ] && exit 0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NAME="sherpa-onnx-$VERSION-osx-arm64-static-no-tts-lib"
curl -fsSL -o "$TMP/lib.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$NAME.tar.bz2"
curl -fsSL -o "$TMP/c-api.h" "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VERSION/sherpa-onnx/c-api/c-api.h"
echo "$LIB_SHA  $TMP/lib.tar.bz2" | shasum -a 256 -c - >/dev/null
echo "$HEADER_SHA  $TMP/c-api.h" | shasum -a 256 -c - >/dev/null
tar -xjf "$TMP/lib.tar.bz2" -C "$TMP"
mkdir -p "$DEST/lib" "$DEST/include/sherpa-onnx/c-api"
cp "$TMP/$NAME/lib/"*.a "$DEST/lib/"
cp "$TMP/c-api.h" "$DEST/include/sherpa-onnx/c-api/c-api.h"
touch "$STAMP"
echo "sherpa-onnx $VERSION in $DEST"
