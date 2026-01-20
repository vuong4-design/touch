#export THEOS_DEVICE_IP = 192.168.101.245

include $(THEOS)/makefiles/common.mk

TOOL_NAME = zxtouchd zxtouchb
zxtouchd_ARCH = arm64e arm64
zxtouchb_ARCH = arm64e arm64

zxtouchd_FILES = main.mm
zxtouchb_FILES = main.mm
zxtouchd_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchb_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchd_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG
zxtouchb_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG

include $(THEOS_MAKE_PATH)/tool.mk
