# V154 rootless ElleKit injection TEST-ONLY. No network deployment.
# Must build for the independent, already validated V150 research app ONLY.
ARCHS = arm64
TARGET = iphone:clang:latest:16.6
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = IPACompatV154
IPACompatV154_FILES = Tweak.m
IPACompatV154_FRAMEWORKS = Foundation
IPACompatV154_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -O2 -fvisibility=hidden
IPACompatV154_LDFLAGS = -Wl,-dead_strip
include $(THEOS_MAKE_PATH)/tweak.mk
