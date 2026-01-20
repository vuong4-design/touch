#include "IPCMessagePort.h"
#include "IPCConstants.h"
#include "HardwareKey.h"
#include "Task.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

static CFMessagePortRef ipcLocalPort = NULL;
static CFRunLoopSourceRef ipcRunLoopSource = NULL;

static CFDataRef handleIPCMessage(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info)
{
    if (!data) {
        return NULL;
    }

    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    if (!bytes || length <= 0) {
        return NULL;
    }

    NSString *command = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    if (!command) {
        return NULL;
    }

    if ([command isEqualToString:[NSString stringWithUTF8String:kZXTouchIPCCommandHome]]) {
        NSError *error = nil;
        sendHardwareKeyEventFromRawData((UInt8 *)"1;;1", &error);
        sendHardwareKeyEventFromRawData((UInt8 *)"0;;1", &error);
        const char *response = "0\r\n";
        return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)response, strlen(response));
    }

    NSString *taskPrefix = [NSString stringWithUTF8String:kZXTouchIPCCommandTaskPrefix];
    if ([command hasPrefix:taskPrefix]) {
        NSString *rawTask = [command substringFromIndex:[taskPrefix length]];
        if ([rawTask length] > 0) {
            processTask((UInt8 *)[rawTask UTF8String]);
        }
        const char *response = "0\r\n";
        return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)response, strlen(response));
    }

    const char *response = "1;;unknown_command\r\n";
    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)response, strlen(response));
}

void startIPCServer()
{
    if (ipcLocalPort) {
        return;
    }

    CFMessagePortContext context = {0, NULL, NULL, NULL, NULL};
    Boolean shouldFree = false;
    ipcLocalPort = CFMessagePortCreateLocal(kCFAllocatorDefault,
                                            kZXTouchIPCPortName,
                                            handleIPCMessage,
                                            &context,
                                            &shouldFree);
    if (!ipcLocalPort) {
        NSLog(@"### com.zjx.springboard: failed to create IPC message port.");
        return;
    }

    ipcRunLoopSource = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, ipcLocalPort, 0);
    if (!ipcRunLoopSource) {
        CFRelease(ipcLocalPort);
        ipcLocalPort = NULL;
        return;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), ipcRunLoopSource, kCFRunLoopCommonModes);
    NSLog(@"### com.zjx.springboard: IPC message port started.");
}
