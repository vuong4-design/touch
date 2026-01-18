// H264Stream.xm
#include "H264Stream.h"
#include "Screen.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
#include <string.h>

static const int kH264StreamPort = 7001;
static const int kH264TargetWidth = 667;
static const int kH264TargetHeight = 375;
static const int kH264TargetFPS = 20;
static const int kH264KeyframeIntervalSeconds = 2;
static const int kPCRIntervalFrames = 10; // PCR every N frames (ok for live preview)

// TS PIDs
static const uint16_t kTSPatPid = 0x0000;
static const uint16_t kTSPmtPid = 0x0100;
static const uint16_t kTSVideoPid = 0x0101;
static const uint16_t kTSProgramNumber = 1;

// Only one viewer at a time (per your requirement)
static _Atomic int gActiveClientFd = -1;

@interface ZXTH264EncoderContext : NSObject
@property(nonatomic, strong) NSMutableData *encodedData;
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL isKeyframe;
@end

@implementation ZXTH264EncoderContext
@end

#pragma mark - Utils

static void appendAnnexBHeader(NSMutableData *data) {
    static const uint8_t header[] = {0x00, 0x00, 0x00, 0x01};
    [data appendBytes:header length:4];
}

static bool sendAll(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t r = send(fd, buf + sent, len - sent, 0);
        if (r > 0) {
            sent += (size_t)r;
        } else if (r < 0 && errno == EINTR) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

static uint32_t mpegCrc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint32_t)data[i] << 24;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80000000) ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
        }
    }
    return crc;
}

#pragma mark - PAT / PMT

static NSData *buildPAT(uint8_t cc) {
    uint8_t sec[16] = {0};
    size_t i = 0;

    sec[i++] = 0x00; // table_id
    sec[i++] = 0xB0; // section_syntax_indicator + reserved + section_length hi (filled later)
    sec[i++] = 0x00; // section_length lo (filled later)

    sec[i++] = 0x00; // transport_stream_id hi
    sec[i++] = 0x01; // transport_stream_id lo

    sec[i++] = 0xC1; // version_number + current_next_indicator
    sec[i++] = 0x00; // section_number
    sec[i++] = 0x00; // last_section_number

    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = kTSProgramNumber & 0xFF;
    sec[i++] = 0xE0 | ((kTSPmtPid >> 8) & 0x1F);
    sec[i++] = kTSPmtPid & 0xFF;

    size_t slen = (i - 3) + 4; // bytes after section_length (from TSID) + CRC
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = (uint8_t)(slen & 0xFF);

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = (uint8_t)(crc >> 24);
    sec[i++] = (uint8_t)(crc >> 16);
    sec[i++] = (uint8_t)(crc >> 8);
    sec[i++] = (uint8_t)(crc);

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPatPid >> 8) & 0x1F); // payload_unit_start
    pkt[2] = (uint8_t)(kTSPatPid & 0xFF);
    pkt[3] = 0x10 | (cc & 0x0F); // payload only
    pkt[4] = 0x00; // pointer_field

    memcpy(pkt + 5, sec, i);
    memset(pkt + 5 + i, 0xFF, 188 - 5 - i);

    return [NSData dataWithBytes:pkt length:188];
}

static NSData *buildPMT(uint8_t cc) {
    uint8_t sec[32] = {0};
    size_t i = 0;

    sec[i++] = 0x02; // table_id
    sec[i++] = 0xB0; // section_syntax_indicator + reserved + section_length hi (filled later)
    sec[i++] = 0x00; // section_length lo (filled later)

    sec[i++] = (kTSProgramNumber >> 8) & 0xFF;
    sec[i++] = kTSProgramNumber & 0xFF;
    sec[i++] = 0xC1; // version + current_next
    sec[i++] = 0x00; // section_number
    sec[i++] = 0x00; // last_section_number

    // PCR PID
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = (uint8_t)(kTSVideoPid & 0xFF);

    // program_info_length
    sec[i++] = 0xF0;
    sec[i++] = 0x00;

    // one stream: H264
    sec[i++] = 0x1B; // stream_type H.264
    sec[i++] = 0xE0 | ((kTSVideoPid >> 8) & 0x1F);
    sec[i++] = (uint8_t)(kTSVideoPid & 0xFF);
    sec[i++] = 0xF0; // ES_info_length
    sec[i++] = 0x00;

    size_t slen = (i - 3) + 4;
    sec[1] = 0xB0 | ((slen >> 8) & 0x0F);
    sec[2] = (uint8_t)(slen & 0xFF);

    uint32_t crc = mpegCrc32(sec, i);
    sec[i++] = (uint8_t)(crc >> 24);
    sec[i++] = (uint8_t)(crc >> 16);
    sec[i++] = (uint8_t)(crc >> 8);
    sec[i++] = (uint8_t)(crc);

    uint8_t pkt[188] = {0};
    pkt[0] = 0x47;
    pkt[1] = 0x40 | ((kTSPmtPid >> 8) & 0x1F);
    pkt[2] = (uint8_t)(kTSPmtPid & 0xFF);
    pkt[3] = 0x10 | (cc & 0x0F); // payload only
    pkt[4] = 0x00; // pointer_field

    memcpy(pkt + 5, sec, i);
    memset(pkt + 5 + i, 0xFF, 188 - 5 - i);

    return [NSData dataWithBytes:pkt length:188];
}

#pragma mark - TS packet writer

static bool writeTSPackets(int fd,
                           uint16_t pid,
                           const uint8_t *payload,
                           size_t len,
                           bool start,
                           bool addPCR,
                           uint64_t pts90k,
                           uint8_t *cc) {
    size_t off = 0;

    while (off < len) {
        uint8_t pkt[188] = {0};
        bool first = start && (off == 0);
        bool pcrHere = addPCR && first;

        pkt[0] = 0x47;
        pkt[1] = (uint8_t)(((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)));
        pkt[2] = (uint8_t)(pid & 0xFF);
        pkt[3] = (uint8_t)(*cc & 0x0F);
        *cc = (uint8_t)((*cc + 1) & 0x0F);

        size_t payloadMax = 184;
        size_t remain = len - off;
        size_t copy = (remain < payloadMax) ? remain : payloadMax;

        if (pcrHere || copy < payloadMax) {
            // adaptation + payload
            pkt[3] |= 0x30;

            uint8_t *ad = pkt + 4;
            size_t ai = 2;

            ad[1] = pcrHere ? 0x10 : 0x00; // PCR flag if present

            if (pcrHere) {
                // PCR base is 90kHz ticks, encode as PCR_base with ext=0.
                uint64_t base = pts90k & ((1ULL << 33) - 1);

                ad[2] = (uint8_t)((base >> 25) & 0xFF);
                ad[3] = (uint8_t)((base >> 17) & 0xFF);
                ad[4] = (uint8_t)((base >> 9) & 0xFF);
                ad[5] = (uint8_t)((base >> 1) & 0xFF);
                ad[6] = (uint8_t)(((base & 1) << 7) | 0x7E);
                ad[7] = 0x00; // ext = 0
                ai = 8;
            }

            // We want the payload to start at pkt[4 + 1 + adaptLen]
            // adaptLen = (ai - 1) + stuffing
            size_t adaptLen = ai - 1;
            size_t stuff = payloadMax - (ai + copy);
            adaptLen += stuff;

            ad[0] = (uint8_t)adaptLen;
            memset(ad + ai, 0xFF, stuff);

            memcpy(pkt + 4 + 1 + adaptLen, payload + off, copy);
        } else {
            // payload only
            pkt[3] |= 0x10;
            memcpy(pkt + 4, payload + off, copy);
        }

        if (!sendAll(fd, pkt, 188)) return false;
        off += copy;
    }
    return true;
}

#pragma mark - Encoder

static void H264OutputCallback(void *outputCallbackRefCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTEncodeInfoFlags infoFlags,
                              CMSampleBufferRef sampleBuffer) {
    (void)outputCallbackRefCon;
    (void)infoFlags;

    if (!sourceFrameRefCon) return;

    // NOTE: This release must match the CFBridgingRetain done per-frame.
    ZXTH264EncoderContext *ctx = (ZXTH264EncoderContext *)CFBridgingRelease(sourceFrameRefCon);

    if (status != noErr || !sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
        dispatch_semaphore_signal(ctx.semaphore);
        return;
    }

    BOOL isKeyframe = NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        isKeyframe = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
    }
    ctx.isKeyframe = isKeyframe;

    // Insert SPS/PPS on keyframes (Annex-B) to help decoders lock quickly
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (isKeyframe && fmt) {
        const uint8_t *sps = NULL, *pps = NULL;
        size_t spsSz = 0, ppsSz = 0;

        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsSz, NULL, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsSz, NULL, NULL) == noErr) {
            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:sps length:spsSz];
            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:pps length:ppsSz];
        }
    }

    // Convert AVCC to Annex-B
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLen = 0;
    char *ptr = NULL;

    if (bb && CMBlockBufferGetDataPointer(bb, 0, NULL, &totalLen, &ptr) == noErr) {
        size_t off = 0;
        while (off + 4 <= totalLen) {
            uint32_t nalLen = 0;
            memcpy(&nalLen, ptr + off, 4);
            nalLen = CFSwapInt32BigToHost(nalLen);
            off += 4;
            if (off + nalLen > totalLen) break;

            appendAnnexBHeader(ctx.encodedData);
            [ctx.encodedData appendBytes:(ptr + off) length:nalLen];
            off += nalLen;
        }
    }

    dispatch_semaphore_signal(ctx.semaphore);
}

static VTCompressionSessionRef createEncoder(void) {
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                             kH264TargetWidth,
                                             kH264TargetHeight,
                                             kCMVideoCodecType_H264,
                                             NULL,
                                             NULL,
                                             NULL,
                                             H264OutputCallback,
                                             NULL,
                                             &s);
    if (st != noErr || !s) return NULL;

    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFTypeRef)@(kH264TargetFPS * kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFTypeRef)@(kH264KeyframeIntervalSeconds));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFTypeRef)@(kH264TargetFPS));
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFTypeRef)@(2000000));

    VTCompressionSessionPrepareToEncodeFrames(s);
    return s;
}

#pragma mark - Stream loop

static bool setClientSocketOptions(int fd) {
    int one = 1;

    // Reduce latency (disable Nagle)
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    // Avoid SIGPIPE if peer disconnects (iOS has SO_NOSIGPIPE)
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif

    return true;
}

static void sendTablesIfNeeded(int fd,
                               bool force,
                               uint8_t *patCC,
                               uint8_t *pmtCC,
                               bool *sentOnce) {
    if (!force && *sentOnce) return;

    NSData *pat = buildPAT((*patCC)++);
    NSData *pmt = buildPMT((*pmtCC)++);
    (void)sendAll(fd, (const uint8_t *)pat.bytes, 188);
    (void)sendAll(fd, (const uint8_t *)pmt.bytes, 188);
    *sentOnce = true;
}

static void streamLoop(int fd) {
    @autoreleasepool {
        setClientSocketOptions(fd);

        VTCompressionSessionRef enc = createEncoder();
        if (!enc) {
            shutdown(fd, SHUT_RDWR);
            close(fd);
            int exp = fd;
            atomic_compare_exchange_strong(&gActiveClientFd, &exp, -1);
            return;
        }

        uint8_t patCC = 0, pmtCC = 0, vidCC = 0;
        int64_t frame = 0;
        bool sentTables = false;

        // Send PAT/PMT immediately to help ffplay detect TS faster
        sendTablesIfNeeded(fd, true, &patCC, &pmtCC, &sentTables);

        while (1) {
            @autoreleasepool {
                CGImageRef img = [Screen createScreenShotCGImageRef];
                if (!img) break;

                ZXTH264EncoderContext *ctx = [[ZXTH264EncoderContext alloc] init];
                ctx.encodedData = [NSMutableData data];
                ctx.semaphore = dispatch_semaphore_create(0);

                void *ref = (void *)CFBridgingRetain(ctx);

                CVPixelBufferRef pb = NULL;
                CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault,
                                                  kH264TargetWidth,
                                                  kH264TargetHeight,
                                                  kCVPixelFormatType_32BGRA,
                                                  NULL,
                                                  &pb);
                if (cr != kCVReturnSuccess || !pb) {
                    CFRelease((CFTypeRef)ref);
                    CGImageRelease(img);
                    break;
                }

                CVPixelBufferLockBaseAddress(pb, 0);

                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef cg = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb),
                                                        kH264TargetWidth,
                                                        kH264TargetHeight,
                                                        8,
                                                        CVPixelBufferGetBytesPerRow(pb),
                                                        cs,
                                                        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);

                if (cg) {
                    CGContextDrawImage(cg, CGRectMake(0, 0, kH264TargetWidth, kH264TargetHeight), img);
                    CGContextRelease(cg);
                }
                CGColorSpaceRelease(cs);

                CVPixelBufferUnlockBaseAddress(pb, 0);

                // Force keyframe on first frame so decoder gets SPS/PPS+IDR quickly
                CFMutableDictionaryRef opts = NULL;
                if (frame == 0) {
                    opts = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                                                     &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
                    if (opts) {
                        CFDictionarySetValue(opts, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
                    }
                }

                OSStatus st = VTCompressionSessionEncodeFrame(enc,
                                                             pb,
                                                             CMTimeMake(frame, kH264TargetFPS),
                                                             kCMTimeInvalid,
                                                             opts,
                                                             ref,
                                                             NULL);

                if (opts) CFRelease(opts);

                CVPixelBufferRelease(pb);
                CGImageRelease(img);

                if (st != noErr) {
                    // callback won't fire => avoid deadlock & release retained ctx
                    CFRelease((CFTypeRef)ref);
                    dispatch_semaphore_signal(ctx.semaphore);
                    break;
                }

                dispatch_semaphore_wait(ctx.semaphore, DISPATCH_TIME_FOREVER);

                // Refresh tables on keyframe (helps some players on reconnect)
                if (ctx.isKeyframe) {
                    sendTablesIfNeeded(fd, true, &patCC, &pmtCC, &sentTables);
                }

                // Build PES with PTS only
                uint64_t pts = (uint64_t)(frame * 90000 / kH264TargetFPS);

                uint8_t pes[14] = {
                    0x00, 0x00, 0x01, 0xE0, // start code + stream_id
                    0x00, 0x00,             // PES length (0 for video)
                    0x80,                   // '10' + flags
                    0x80,                   // PTS only
                    0x05,                   // header length
                    (uint8_t)(0x21 | ((pts >> 29) & 0x0E)),
                    (uint8_t)(pts >> 22),
                    (uint8_t)(0x01 | ((pts >> 14) & 0xFE)),
                    (uint8_t)(pts >> 7),
                    (uint8_t)(0x01 | ((pts << 1) & 0xFE))
                };

                NSMutableData *payload = [NSMutableData dataWithBytes:pes length:sizeof(pes)];
                [payload appendData:ctx.encodedData];

                bool addPCR = ((frame % kPCRIntervalFrames) == 0);

                if (!writeTSPackets(fd,
                                    kTSVideoPid,
                                    (const uint8_t *)payload.bytes,
                                    payload.length,
                                    true,
                                    addPCR,
                                    pts,
                                    &vidCC)) {
                    break;
                }

                frame++;
                usleep((useconds_t)(1000000 / kH264TargetFPS));
            }
        }

        VTCompressionSessionInvalidate(enc);
        CFRelease(enc);

        shutdown(fd, SHUT_RDWR);
        close(fd);

        int exp = fd;
        atomic_compare_exchange_strong(&gActiveClientFd, &exp, -1);
    }
}

#pragma mark - Server

void startH264StreamServer(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return;

        int yes = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons(kH264StreamPort);

        if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) {
            close(s);
            return;
        }

        if (listen(s, 16) != 0) {
            close(s);
            return;
        }

        while (1) {
            int c = accept(s, NULL, NULL);
            if (c < 0) continue;

            // only one viewer: if already active, reject
            int exp = -1;
            if (!atomic_compare_exchange_strong(&gActiveClientFd, &exp, c)) {
                shutdown(c, SHUT_RDWR);
                close(c);
                continue;
            }

            // Run per-client in background queue
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                streamLoop(c);
            });
        }
    });
}
