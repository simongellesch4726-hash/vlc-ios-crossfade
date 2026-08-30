ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Crossfade
Crossfade_FILES = Tweak.xm CrossfadeState.m
Crossfade_CFLAGS = -fobjc-arc
Crossfade_FRAMEWORKS = UIKit Foundation AVFoundation MediaPlayer
Crossfade_PRIVATE_FRAMEWORKS = CoreMedia
Crossfade_LIBRARIES = substrate
Crossfade_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
