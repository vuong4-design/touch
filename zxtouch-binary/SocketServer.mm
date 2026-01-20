// TODO: multiple client write back support

#include "SocketServer.h"
#include <string.h>

CFSocketRef socketRef;
CFWriteStreamRef writeStreamRef = NULL;
CFReadStreamRef readStreamRef = NULL;
static NSMutableDictionary *socketClients = NULL;

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo);
static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

// Reference: https://www.jianshu.com/p/9353105a9129

static void handleDaemonMessage(UInt8 *buff, CFWriteStreamRef client)
{
    if (!buff) {
        return;
    }
    NSLog(@"### com.zjx.zxtouchd: received task payload: %s", buff);
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

        NSLog(@"### com.zjx.zxtouchd: connection waiting");
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
        NSLog(@"### com.zjx.zxtouchd: connection starts", inet_ntoa(addr_in-> sin_addr), addr_in->sin_port);

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
