#ifndef ZXTOUCH_IPC_CONSTANTS_H
#define ZXTOUCH_IPC_CONSTANTS_H

#include <CoreFoundation/CoreFoundation.h>

static CFStringRef const kZXTouchIPCPortName = CFSTR("com.zjx.zxtouchd.springboard");
static const char *const kZXTouchIPCCommandHome = "CMD_HOME";
static const char *const kZXTouchIPCCommandTaskPrefix = "TASK::";

#endif
