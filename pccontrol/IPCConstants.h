#ifndef ZXTOUCH_IPC_CONSTANTS_H
#define ZXTOUCH_IPC_CONSTANTS_H

#include <CoreFoundation/CoreFoundation.h>

static CFStringRef const kZXTouchIPCPortName = CFSTR("com.zjx.zxtouchd.springboard");
static const char *const kZXTouchIPCCommandHome = "CMD_HOME";
static const char *const kZXTouchIPCCommandPing = "CMD_PING";
static const char *const kZXTouchIPCCommandTaskPrefix = "TASK::";
static NSString *const kZXTouchIPCReadyMarkerPath = @"/var/mobile/Library/ZXTouch/ipc_ready";
static NSString *const kZXTouchTweakLoadedMarkerPath = @"/var/mobile/Library/ZXTouch/tweak_loaded";

#endif
