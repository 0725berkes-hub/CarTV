#!/bin/bash
# Downloads the official MobileVLCKit xcframework from VideoLAN into Packages/VLCKit/Vendor.
# The binary is ~1.1 GB unpacked and is git-ignored; run this once after cloning.
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-${VERSION}.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Packages/VLCKit/Vendor"
DEST="$VENDOR/MobileVLCKit.xcframework"

if [ -d "$DEST" ]; then
  echo "MobileVLCKit.xcframework already present at $DEST"
  exit 0
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading MobileVLCKit ${VERSION} …"
curl -L --progress-bar -o "$TMP/vlc.tar.xz" "$URL"
echo "Extracting …"
tar -xJf "$TMP/vlc.tar.xz" -C "$TMP"
mv "$TMP"/MobileVLCKit-binary/MobileVLCKit.xcframework "$DEST"
echo "Done → $DEST"
