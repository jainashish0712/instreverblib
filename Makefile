TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramReverb InstagramDash1440p

InstagramReverb_FILES = InstagramReverb.m InstagramReverbUI.m fishhook.c
InstagramReverb_CFLAGS = -fobjc-arc -O3
InstagramReverb_LDFLAGS = -lc++
InstagramReverb_FRAMEWORKS = AudioToolbox MediaToolbox CoreMedia Foundation UIKit CoreGraphics QuartzCore MediaPlayer AVFoundation

InstagramDash1440p_FILES = InstagramDash1440p.mm InstagramDash1440pUI.m InstagramWifiSpoofer.m fishhook.c
InstagramDash1440p_CFLAGS = -fobjc-arc -O3
InstagramDash1440p_LDFLAGS = -lc++
InstagramDash1440p_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore AVFoundation CoreMedia MediaToolbox SystemConfiguration Network

include $(THEOS_MAKE_PATH)/tweak.mk
