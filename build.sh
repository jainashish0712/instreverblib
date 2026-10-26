#!/usr/bin/env bash
set -e

echo "Building InstagramReverb.dylib for arm64 iOS..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")

FRAMEWORKS="-framework Foundation -framework AVFoundation -framework AudioToolbox -framework MediaToolbox -framework CoreMedia -framework UIKit -framework CoreGraphics -framework QuartzCore -framework MediaPlayer -framework SystemConfiguration -framework Network"

if [ -n "$SDK_PATH" ]; then
    xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS \
        -O3 -fobjc-arc \
        fishhook.c InstagramReverb.m InstagramReverbUI.m InstagramWifiSpoofer.m \
        -o InstagramReverb.dylib
else
    echo "Using direct clang..."
    clang -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS \
        -O3 -fobjc-arc \
        fishhook.c InstagramReverb.m InstagramReverbUI.m InstagramWifiSpoofer.m \
        -o InstagramReverb.dylib
fi

echo "Successfully built InstagramReverb.dylib!"
