#export THEOS_DEVICE_IP = 192.168.101.245

include $(THEOS)/makefiles/common.mk

TOOL_NAME = zxtouchd zxtouchb
zxtouchd_ARCH = arm64e arm64
zxtouchb_ARCH = arm64e arm64

zxtouchd_FILES = main.mm SocketServer.mm TemplateMatch.xm ScreenMatch.xm Screen.xm Common.xm
zxtouchb_FILES = main.mm SocketServer.mm TemplateMatch.xm ScreenMatch.xm Screen.xm Common.xm
zxtouchd_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchb_FRAMEWORKS = CoreFoundation UIKit CoreGraphics
zxtouchd_PRIVATE_FRAMEWORKS = IOKit
zxtouchb_PRIVATE_FRAMEWORKS = IOKit
zxtouchd_EXTRA_FRAMEWORKS = opencv2
zxtouchb_EXTRA_FRAMEWORKS = opencv2
zxtouchd_CFLAGS += -F$(THEOS_PROJECT_DIR)/frameworks
zxtouchb_CFLAGS += -F$(THEOS_PROJECT_DIR)/frameworks
zxtouchd_CFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers
zxtouchb_CFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers
zxtouchd_CCFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers
zxtouchb_CCFLAGS += -I$(THEOS_PROJECT_DIR)/frameworks/opencv2.framework/Versions/A/Headers
zxtouchd_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG
zxtouchb_CFLAGS = -fobjc-arc -Wno-error -Wno-module-import-in-extern-c -O2 -s -DNDEBUG

include $(THEOS_MAKE_PATH)/tool.mk
