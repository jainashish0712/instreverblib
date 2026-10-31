#!/usr/bin/env bash
set -e

echo "Building iOS tweaks for arm64..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")

FRAMEWORKS_REVERB="-framework Foundation -framework AVFoundation -framework AudioToolbox -framework MediaToolbox -framework CoreMedia -framework UIKit -framework CoreGraphics -framework QuartzCore -framework MediaPlayer"
FRAMEWORKS_DASH="-framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework AVFoundation -framework CoreMedia -framework MediaToolbox -framework SystemConfiguration -framework Network"

if [ -n "$SDK_PATH" ]; then
    echo "Compiling InstagramReverb.dylib (Audio DSP Engine)..."
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS_REVERB \
        -O3 -fobjc-arc \
        fishhook.c InstagramReverb.m InstagramReverbUI.m -lc++ \
        -o InstagramReverb.dylib

    echo "Compiling InstagramDash1440p.dylib (VP9 1440p DASH Engine)..."
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS_DASH \
        -O3 -fobjc-arc \
        fishhook.c InstagramWifiSpoofer.m InstagramDash1440p.mm InstagramDash1440pUI.m -lc++ \
        -o InstagramDash1440p.dylib
else
    echo "Compiling InstagramReverb.dylib (direct clang)..."
    clang -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS_REVERB \
        -O3 -fobjc-arc \
        fishhook.c InstagramReverb.m InstagramReverbUI.m -lc++ \
        -o InstagramReverb.dylib

    echo "Compiling InstagramDash1440p.dylib (direct clang)..."
    clang -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS_DASH \
        -O3 -fobjc-arc \
        fishhook.c InstagramWifiSpoofer.m InstagramDash1440p.mm InstagramDash1440pUI.m -lc++ \
        -o InstagramDash1440p.dylib
fi

# Also generate Instagram1440p.dylib as direct copy
cp -f InstagramDash1440p.dylib Instagram1440p.dylib

echo "Successfully built both tweaks:"
ls -lh InstagramReverb.dylib InstagramDash1440p.dylib Instagram1440p.dylib
