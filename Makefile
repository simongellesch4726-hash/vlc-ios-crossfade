ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:15.0
SUBPROJECTS = Crossfade Preferences

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
