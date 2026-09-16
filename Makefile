export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:26.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard com.apple.shortcuts

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LockShot
LockShot_FILES = LockShot.x
LockShot_CFLAGS = -fobjc-arc
LockShot_FRAMEWORKS = UIKit
LockShot_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
