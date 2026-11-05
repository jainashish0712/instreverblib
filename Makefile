TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramDash1440p

InstagramDash1440p_FILES = InstagramDash1440p.mm InstagramDash1440pUI.m InstagramWifiSpoofer.m fishhook.c
InstagramDash1440p_CFLAGS = -fobjc-arc -O3
InstagramDash1440p_LDFLAGS = -lc++
InstagramDash1440p_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore CoreMedia SystemConfiguration Network

include $(THEOS_MAKE_PATH)/tweak.mk
