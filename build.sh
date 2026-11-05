#!/usr/bin/env bash
set -e

echo "Building InstagramDash1440p.dylib for arm64 iOS..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")

FRAMEWORKS="-framework Foundation -framework CoreMedia -framework UIKit -framework CoreGraphics -framework QuartzCore -framework SystemConfiguration -framework Network"
SRCS="fishhook.c InstagramWifiSpoofer.m InstagramDash1440p.mm InstagramDash1440pUI.m"

if [ -n "$SDK_PATH" ]; then
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS \
        -O3 -fobjc-arc \
        $SRCS -lc++ \
        -o InstagramDash1440p.dylib
else
    echo "Using direct clang..."
    clang -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS \
        -O3 -fobjc-arc \
        $SRCS -lc++ \
        -o InstagramDash1440p.dylib
fi

# Compatibility copy for existing sideloading profiles and release pipelines
cp -f InstagramDash1440p.dylib InstagramReverb.dylib

echo "Successfully built InstagramDash1440p.dylib and created InstagramReverb.dylib alias!"
