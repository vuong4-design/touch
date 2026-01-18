#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 1280;
static const int kH264TargetHeight = 720;
static const int kH264TargetFPS = 20;
static const int kH264KeyframeIntervalSeconds = 2;

@interface ZXTH264EncoderContext : NSObject
@property(nonatomic, strong) NSMutableData *encodedData;
@property(nonatomic) dispatch_semaphore_t semaphore;
@end

@implementation ZXTH264EncoderContext
@end

static void appendAnnexBHeader(NSMutableData *data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    [data appendBytes:header length:sizeof(header)];
}

static void H264OutputCallback(void *outputCallbackRefCon,
                               void *sourceFrameRefCon,
                               OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
    (void)outputCallbackRefCon;
    (void)infoFlags;
    if (!sourceFrameRefCon) {
        return;
    }
    ZXTH264EncoderContext *context = CFBridgingRelease(sourceFrameRefCon);
    if (status != noErr || !sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
        dispatch_semaphore_signal(context.semaphore);
        return;
    }

    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        BOOL notSync = CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
        isKeyframe = !notSync;
    }

    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (isKeyframe && formatDesc) {
        const uint8_t *sps = NULL;
        const uint8_t *pps = NULL;
        size_t spsSize = 0;
        size_t ppsSize = 0;
        size_t spsCount = 0;
        size_t ppsCount = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 0, &sps, &spsSize, &spsCount, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, 1, &pps, &ppsSize, &ppsCount, NULL) == noErr) {
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:sps length:spsSize];
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:pps length:ppsSize];
        }
    }

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = 0;
    char *dataPointer = NULL;
    if (CMBlockBufferGetDataPointer(dataBuffer, 0, NULL, &length, &dataPointer) == noErr) {
        size_t offset = 0;
        const size_t headerLength = 4;
        while (offset + headerLength < length) {
            uint32_t nalLength = 0;
            memcpy(&nalLength, dataPointer + offset, headerLength);
            nalLength = CFSwapInt32BigToHost(nalLength);
            appendAnnexBHeader(context.encodedData);
            [context.encodedData appendBytes:(dataPointer + offset + headerLength) length:nalLength];
            offset += headerLength + nalLength;
        }
    }

    dispatch_semaphore_signal(context.semaphore);
}

static bool sendAll(int socketFd, const uint8_t *buffer, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t result = send(socketFd, buffer + sent, length - sent, MSG_NOSIGNAL);
        if (result <= 0) {
            return false;
        }
        sent += (size_t)result;
    }
    return true;
}

static CVPixelBufferRef createPixelBufferFromCGImage(CGImageRef image, size_t width, size_t height) {
    NSDictionary *attributes = @{
        (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

static NSData *encodeFrame(VTCompressionSessionRef session, CGImageRef image, CMTime frameTime) {
    ZXTH264EncoderContext *context = [[ZXTH264EncoderContext alloc] init];
    context.encodedData = [NSMutableData data];
    context.semaphore = dispatch_semaphore_create(0);
    void *contextRef = (void *)CFBridgingRetain(context);

    size_t width = kH264TargetWidth;
    size_t height = kH264TargetHeight;
    CVPixelBufferRef pixelBuffer = createPixelBufferFromCGImage(image, width, height);
    if (!pixelBuffer) {
        return nil;
    }

    VTEncodeInfoFlags flags = 0;
    OSStatus status = VTCompressionSessionEncodeFrame(session, pixelBuffer, frameTime, kCMTimeInvalid, NULL, contextRef, &flags);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr) {
        CFRelease((CFTypeRef)contextRef);
        return nil;
    }

    dispatch_semaphore_wait(context.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)));
    return context.encodedData;
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                                 kH264TargetWidth,
                                                 kH264TargetHeight,
                                                 kCMVideoCodecType_H264,
                                                 NULL,
                                                 NULL,
                                                 NULL,
                                                 H264OutputCallback,
                                                 NULL,
                                                 &session);
    if (status != noErr || !session) {
        return NULL;
    }

    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(kH264TargetFPS * kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(2000000));
    VTCompressionSessionPrepareToEncodeFrames(session);
    return session;
}

static void streamLoop(int clientSocket) {
    VTCompressionSessionRef encoder = createEncoder();
    if (!encoder) {
        close(clientSocket);
        return;
    }

    int64_t frameIndex = 0;
    while (clientSocket >= 0) {
        CGImageRef image = [Screen createScreenShotCGImageRef];
        if (!image) {
            break;
        }

        CMTime frameTime = CMTimeMake(frameIndex, kH264TargetFPS);
        NSData *encoded = encodeFrame(encoder, image, frameTime);
        CGImageRelease(image);

        if (!encoded || encoded.length == 0) {
            break;
        }

        if (!sendAll(clientSocket, (const uint8_t *)encoded.bytes, encoded.length)) {
            break;
        }
        frameIndex++;
        usleep((useconds_t)(1000000 / kH264TargetFPS));
    }

    VTCompressionSessionInvalidate(encoder);
    CFRelease(encoder);
    close(clientSocket);
}

void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (serverSocket < 0) {
            return;
        }

        int reuse = 1;
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(kH264StreamPort);

        if (bind(serverSocket, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            close(serverSocket);
            return;
        }

        if (listen(serverSocket, 1) != 0) {
            close(serverSocket);
            return;
        }

        while (1) {
            int clientSocket = accept(serverSocket, NULL, NULL);
            if (clientSocket < 0) {
                continue;
            }
            int noSigPipe = 1;
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
            streamLoop(clientSocket);
        }
    });
}
