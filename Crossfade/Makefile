ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
THEOS_LAYOUT_DIR = layout

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Crossfade
Crossfade_FILES = Tweak.xm CrossfadeController.m
Crossfade_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
Crossfade_FRAMEWORKS = Foundation UIKit AVFoundation
Crossfade_LIBRARIES = substrate
Crossfade_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
INSTALL_TARGET_PROCESSES = VLC

BUNDLE_NAME = CrossfadePrefs
CrossfadePrefs_FILES = ../Preferences/CrossfadePrefs.m
CrossfadePrefs_FRAMEWORKS = UIKit
CrossfadePrefs_PRIVATE_FRAMEWORKS = Preferences
CrossfadePrefs_INSTALL_PATH = /Library/PreferenceBundles
CrossfadePrefs_RESOURCE_DIRS = ../Preferences/Resources
CrossfadePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
