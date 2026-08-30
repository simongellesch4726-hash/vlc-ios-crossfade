ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Crossfade
Crossfade_FILES = Tweak.xm CrossfadeController.m
Crossfade_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Crossfade_FRAMEWORKS = Foundation UIKit AVFoundation
Crossfade_LIBRARIES = substrate
Crossfade_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
INSTALL_TARGET_PROCESSES = VLC

include $(THEOS_MAKE_PATH)/tweak.mk
