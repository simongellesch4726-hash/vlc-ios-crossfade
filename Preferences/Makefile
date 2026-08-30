ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
THEOS_LAYOUT_DIR = ../layout

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CrossfadePrefs
CrossfadePrefs_FILES = CrossfadePrefs.m
CrossfadePrefs_FRAMEWORKS = UIKit
CrossfadePrefs_PRIVATE_FRAMEWORKS = Preferences
CrossfadePrefs_INSTALL_PATH = /Library/PreferenceBundles
CrossfadePrefs_RESOURCE_DIRS = Resources
CrossfadePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
