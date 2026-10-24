#!/bin/sh
# Re-clone the official MiraBox Device SDK into vendor/ (git-ignored).
# ThirdParty/libtransport/SDK_COMMIT records the commit our copied library came from.
set -e
cd "$(dirname "$0")/.."
[ -d vendor/StreamDock-Device-SDK ] && { echo "vendor/StreamDock-Device-SDK already exists"; exit 0; }
mkdir -p vendor
git clone https://github.com/MiraboxSpace/StreamDock-Device-SDK.git vendor/StreamDock-Device-SDK
git -C vendor/StreamDock-Device-SDK checkout -q "$(cat ThirdParty/libtransport/SDK_COMMIT)"
