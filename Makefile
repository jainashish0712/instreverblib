TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramReverb

InstagramReverb_FILES = InstagramReverb.m InstagramReverbUI.m InstagramWifiSpoofer.m InstagramDash1440p.mm fishhook.c
InstagramReverb_CFLAGS = -fobjc-arc -O3
InstagramReverb_LDFLAGS = -lc++
InstagramReverb_FRAMEWORKS = AudioToolbox MediaToolbox CoreMedia Foundation UIKit CoreGraphics QuartzCore MediaPlayer AVFoundation SystemConfiguration Network

include $(THEOS_MAKE_PATH)/tweak.mk
