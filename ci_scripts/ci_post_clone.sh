#!/bin/sh
# Xcode Cloud: runs right after the clone, before package resolution.
# MobileVLCKit.xcframework (~1.1 GB) is git-ignored; fetch it here so the local
# binary target in Packages/VLCKit resolves.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
sh Scripts/fetch-vlckit.sh
ls Packages/VLCKit/Vendor/MobileVLCKit.xcframework
