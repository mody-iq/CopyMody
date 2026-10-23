TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CopyMody

CopyMody_FILES = Tweak.x
CopyMody_CFLAGS = -fobjc-arc -Wno-unused-variable
CopyMody_FRAMEWORKS = UIKit Foundation
CopyMody_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
