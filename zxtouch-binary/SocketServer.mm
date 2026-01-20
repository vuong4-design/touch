// TODO: multiple client write back support

#include "SocketServer.h"
#include "IPCConstants.h"
#include <string.h>
#include <ctype.h>
#include <dispatch/dispatch.h>

CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

// Reference: https://www.jianshu.com/p/9353105a9129

static dispatch_queue_t ipcQueue()
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.zjx.zxtouchd.ipc", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static int getTaskTypeFromBuffer(const char *buffer)
{
    if (!buffer || !isdigit(buffer[0]) || !isdigit(buffer[1])) {
        return -1;
    }
    return (buffer[0] - '0') * 10 + (buffer[1] - '0');
}

static bool shouldRouteToSpringBoard(int taskType)
{
    switch (taskType) {
        case 10: // TASK_PERFORM_TOUCH
        case 11: // TASK_PROCESS_BRING_FOREGROUND
        case 12: // TASK_SHOW_ALERT_BOX
        case 14: // TASK_TOUCH_RECORDING_START
        case 15: // TASK_TOUCH_RECORDING_STOP
        case 16: // TASK_CRAZY_TAP
        case 17: // TASK_RAPID_FIRE_TAP
        case 19: // TASK_PLAY_SCRIPT
        case 20: // TASK_PLAY_SCRIPT_FORCE_STOP
        case 21: // TASK_TEMPLATE_MATCH
        case 22: // TASK_SHOW_TOAST
        case 23: // TASK_COLOR_PICKER
        case 24: // TASK_TEXT_INPUT
        case 25: // TASK_GET_DEVICE_INFO
        case 26: // TASK_TOUCH_INDICATOR
        case 27: // TASK_TEXT_RECOGNIZER
        case 28: // TASK_COLOR_SEARCHER
        case 29: // TASK_SCREENSHOT
        case 30: // TASK_HARDWARE_KEY
        case 31: // TASK_APP_KILL
        case 32: // TASK_APP_STATE
        case 33: // TASK_APP_INFO
        case 34: // TASK_FRONTMOST_APP_ID
        case 35: // TASK_FRONTMOST_APP_ORIENTATION
        case 36: // TASK_SET_AUTO_LAUNCH
        case 37: // TASK_LIST_AUTO_LAUNCH
        case 38: // TASK_SET_TIMER
        case 39: // TASK_REMOVE_TIMER
        case 40: // TASK_KEEP_AWAKE
        case 41: // TASK_STOP_SCRIPT
        case 42: // TASK_DIALOG
        case 43: // TASK_CLEAR_DIALOG
        case 44: // TASK_ROOT_DIR
        case 45: // TASK_CURRENT_DIR
        case 46: // TASK_BOT_PATH
        case 90: // TASK_UPDATE_CACHE
            return true;
        default:
            return false;
    }
}

static bool shouldWaitForResponse(int taskType)
{
    switch (taskType) {
        case 14: // TASK_TOUCH_RECORDING_START
        case 15: // TASK_TOUCH_RECORDING_STOP
        case 16: // TASK_CRAZY_TAP
        case 17: // TASK_RAPID_FIRE_TAP
        case 19: // TASK_PLAY_SCRIPT
        case 20: // TASK_PLAY_SCRIPT_FORCE_STOP
        case 36: // TASK_SET_AUTO_LAUNCH
        case 38: // TASK_SET_TIMER
        case 39: // TASK_REMOVE_TIMER
        case 40: // TASK_KEEP_AWAKE
            return false;
        default:
            return true;
    }
}

static CFDataRef sendIPCMessage(const char *payload, bool waitForResponse)
{
    CFDataRef responseData = NULL;
    if (access(kZXTouchIPCReadyMarkerPath, F_OK) != 0) {
        NSLog(@"### com.zjx.zxtouchd: IPC ready marker missing.");
        return NULL;
    }
    CFMessagePortRef remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, kZXTouchIPCPortName);
    if (!remotePort) {
        NSLog(@"### com.zjx.zxtouchd: unable to find SpringBoard IPC port.");
        return NULL;
    }

    if (strcmp(payload, kZXTouchIPCCommandPing) != 0) {
        CFDataRef pingData = CFDataCreate(kCFAllocatorDefault,
                                          (const UInt8 *)kZXTouchIPCCommandPing,
                                          strlen(kZXTouchIPCCommandPing));
        SInt32 pingResult = CFMessagePortSendRequest(remotePort,
                                                     1,
                                                     pingData,
                                                     0.5,
                                                     0.5,
                                                     kCFRunLoopDefaultMode,
                                                     NULL);
        if (pingData) {
            CFRelease(pingData);
        }
        if (pingResult != kCFMessagePortSuccess) {
            NSLog(@"### com.zjx.zxtouchd: IPC ping failed with code %d", (int)pingResult);
            CFRelease(remotePort);
            return NULL;
        }
    }

    CFDataRef messageData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)payload, strlen(payload));
    NSLog(@"### com.zjx.zxtouchd: IPC send payload: %s", payload);
    CFDataRef *responseTarget = waitForResponse ? &responseData : NULL;
    const CFTimeInterval sendTimeout = waitForResponse ? 5.0 : 1.0;
    SInt32 result = CFMessagePortSendRequest(remotePort,
                                             1,
                                             messageData,
                                             sendTimeout,
                                             sendTimeout,
                                             kCFRunLoopDefaultMode,
                                             responseTarget);
    if (result != kCFMessagePortSuccess) {
        NSLog(@"### com.zjx.zxtouchd: IPC send failed with code %d", (int)result);
    } else {
        NSLog(@"### com.zjx.zxtouchd: IPC send success");
    }

    if (messageData) {
        CFRelease(messageData);
    }
    CFRelease(remotePort);
    return responseData;
}

static void handleDaemonMessage(UInt8 *buff, CFWriteStreamRef client)
{
    if (!buff) {
        return;
    }
    NSLog(@"### com.zjx.zxtouchd: received task payload: %s", buff);
    const char *buffer = (const char *)buff;
    const int taskType = getTaskTypeFromBuffer(buffer);
    bool isSpringBoardTask = taskType >= 0 && shouldRouteToSpringBoard(taskType);

    if (strcmp(buffer, kZXTouchIPCCommandHome) == 0) {
        isSpringBoardTask = true;
    }

    if (isSpringBoardTask) {
        char ipcPayload[4096];
        if (strcmp(buffer, kZXTouchIPCCommandHome) == 0) {
            snprintf(ipcPayload, sizeof(ipcPayload), "%s", kZXTouchIPCCommandHome);
        } else {
            snprintf(ipcPayload, sizeof(ipcPayload), "%s%s", kZXTouchIPCCommandTaskPrefix, buffer);
        }
        bool waitForResponse = strcmp(buffer, kZXTouchIPCCommandHome) == 0
            ? true
            : shouldWaitForResponse(taskType);
        __block CFDataRef responseData = NULL;
        if (waitForResponse) {
            dispatch_sync(ipcQueue(), ^{
                responseData = sendIPCMessage(ipcPayload, true);
            });
        } else {
            dispatch_async(ipcQueue(), ^{
                sendIPCMessage(ipcPayload, false);
            });
        }
        if (client) {
            if (responseData) {
                const UInt8 *responseBytes = CFDataGetBytePtr(responseData);
                CFIndex responseLength = CFDataGetLength(responseData);
                if (responseBytes && responseLength > 0) {
                    CFWriteStreamWrite(client, responseBytes, responseLength);
                }
                CFRelease(responseData);
            } else {
                const char *response = waitForResponse ? "1;;ipc_not_ready\r\n" : "0;;queued\r\n";
                CFWriteStreamWrite(client, (const UInt8 *)response, strlen(response));
            }
        }
        return;
    }

    if (client) {
        const char *response = "1;;zxtouchd: task handling not implemented\r\n";
        CFWriteStreamWrite(client, (const UInt8 *)response, strlen(response));
    }
}

void socketServer()
{
    @autoreleasepool {
        CFSocketRef _socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, TCPServerAcceptCallBack, NULL);

        if (_socket == NULL) {
            NSLog(@"### com.zjx.zxtouchd: failed to create socket.");
            return;
        }

        UInt32 reused = 1;

        setsockopt(CFSocketGetNative(_socket), SOL_SOCKET, SO_REUSEADDR, (const void *)&reused, sizeof(reused));

        struct sockaddr_in Socketaddr;
        memset(&Socketaddr, 0, sizeof(Socketaddr));
        Socketaddr.sin_len = sizeof(Socketaddr);
        Socketaddr.sin_family = AF_INET;

        Socketaddr.sin_addr.s_addr = inet_addr(ZXTOUCHD_ADDR);

        Socketaddr.sin_port = htons(ZXTOUCHD_PORT);

        CFDataRef address = CFDataCreate(kCFAllocatorDefault,  (UInt8 *)&Socketaddr, sizeof(Socketaddr));

        if (CFSocketSetAddress(_socket, address) != kCFSocketSuccess) {

            if (_socket) {
                CFRelease(_socket);
            }

            _socket = NULL;
        }

        socketClients = [[NSMutableDictionary alloc] init];

        NSLog(@"### com.zjx.zxtouchd: connection waiting on port %d", ZXTOUCHD_PORT);
        CFRunLoopRef cfrunLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);

        CFRunLoopAddSource(cfrunLoop, source, kCFRunLoopCommonModes);

        CFRelease(source);
        CFRunLoopRun();
    }

}

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo)
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool{
            UInt8 readDataBuff[2048];
            memset(readDataBuff, 0, sizeof(readDataBuff));

            CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, sizeof(readDataBuff));

            if (hasRead > 0) {
                //don't know how it works, copied from https://www.educative.io/edpresso/splitting-a-string-using-strtok-in-c
                for(char * charSep = strtok((char*)readDataBuff, "\r\n"); charSep != NULL; charSep = strtok(NULL, "\r\n")) {
                    UInt8 *buff = (UInt8*)charSep;
                    id temp = [socketClients objectForKey:@((long)readStream)];
                    if (temp != nil) {
                        handleDaemonMessage(buff, (CFWriteStreamRef)[temp longValue]);
                    } else {
                        handleDaemonMessage(buff, NULL);
                    }
                }
            }
        }
    });

}

static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if (kCFSocketAcceptCallBack == type) {

        CFSocketNativeHandle  nativeSocketHandle = *(CFSocketNativeHandle *)data;

        uint8_t name[SOCK_MAXADDRLEN];
        socklen_t namelen = sizeof(name);

        if (getpeername(nativeSocketHandle, (struct sockaddr *)name, &namelen) != 0) {

            NSLog(@"### com.zjx.zxtouchd: ++++++++getpeername+++++++");

            exit(1);
        }

        struct sockaddr_in *addr_in = (struct sockaddr_in *)name;
        NSLog(@"### com.zjx.zxtouchd: connection starts from %s:%d", inet_ntoa(addr_in->sin_addr), ntohs(addr_in->sin_port));

        readStreamRef = NULL;
        writeStreamRef = NULL;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &readStreamRef, &writeStreamRef);

        if (readStreamRef && writeStreamRef) {
            CFReadStreamOpen(readStreamRef);
            CFWriteStreamOpen(writeStreamRef);

            CFStreamClientContext context = {0, NULL, NULL, NULL };

            if (!CFReadStreamSetClient(readStreamRef, kCFStreamEventHasBytesAvailable, readStream, &context)) {
                NSLog(@"### com.zjx.zxtouchd: error 1");
                return;
            }

            CFReadStreamScheduleWithRunLoop(readStreamRef, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

            [socketClients setObject:@((long)writeStreamRef) forKey:@((long)readStreamRef)];
        }
        else
        {
            close(nativeSocketHandle);
        }

    }

}
