// InstagramDash1440p.mm
// Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram
// Forces 1440p DASH video playback via Pure Root-Level Manifest Pruning & Hardware VP9 Decoding
// 100% Native Playback Lifecycle: Zero Hot-Loop Runtime Swizzles, Zero Heap Churn, Maximum Battery Efficiency

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <vector>
#import <string>
#import <cstring>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <dlfcn.h>
#import <CoreMedia/CoreMedia.h>
#import "fishhook.h"
#import "InstagramDash1440p.h"
#import "InstagramWifiSpoofer.h"

NSString * const kInstagramDash1440pStateDidChangeNotification = @"kInstagramDash1440pStateDidChangeNotification";

// Default: Mode 1 (Wi-Fi 1440p, Cellular 1080p ceiling)
static InstagramDash1440pMode g_dashMode = InstagramDash1440pModeWifiOnly;
static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1440p";
static NSString *g_currentResolution = @"";
static NSString *g_currentRepresentationId = @"ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

// Zero-overhead logging stub
#define DashLog(...) do {} while(0)

// ============================================================================
// Public Control & Telemetry Interfaces
// ============================================================================

InstagramDash1440pMode InstagramDash1440p_GetMode(void) {
    pthread_mutex_lock(&g_stateMutex);
    InstagramDash1440pMode m = g_dashMode;
    pthread_mutex_unlock(&g_stateMutex);
    return m;
}

void InstagramDash1440p_SetMode(InstagramDash1440pMode mode) {
    pthread_mutex_lock(&g_stateMutex);
    g_dashMode = mode;
    pthread_mutex_unlock(&g_stateMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

InstagramDash1440pMode InstagramDash1440p_CycleMode(void) {
    pthread_mutex_lock(&g_stateMutex);
    if (g_dashMode == InstagramDash1440pModeWifiOnly) {
        g_dashMode = InstagramDash1440pModeAlways1440p;
    } else if (g_dashMode == InstagramDash1440pModeAlways1440p) {
        g_dashMode = InstagramDash1440pModeDisabled;
    } else {
        g_dashMode = InstagramDash1440pModeWifiOnly;
    }
    InstagramDash1440pMode newMode = g_dashMode;
    pthread_mutex_unlock(&g_stateMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
    return newMode;
}

NSString *InstagramDash1440p_GetModeName(void) {
    InstagramDash1440pMode m = InstagramDash1440p_GetMode();
    switch (m) {
        case InstagramDash1440pModeWifiOnly:
            return @"WiFi 1440p (Cell 1080p)";
        case InstagramDash1440pModeAlways1440p:
            return @"All 1440p (WiFi+Cell)";
        case InstagramDash1440pModeDisabled:
            return @"Disabled (IG Default)";
    }
    return @"Unknown";
}

BOOL InstagramDash1440p_IsEnabled(void) {
    return InstagramDash1440p_GetMode() != InstagramDash1440pModeDisabled;
}

void InstagramDash1440p_SetEnabled(BOOL enabled) {
    InstagramDash1440p_SetMode(enabled ? InstagramDash1440pModeWifiOnly : InstagramDash1440pModeDisabled);
}

BOOL InstagramDash1440p_ToggleEnabled(void) {
    InstagramDash1440pMode m = InstagramDash1440p_CycleMode();
    return m != InstagramDash1440pModeDisabled;
}

BOOL InstagramDash1440p_IsActual1440p(void) {
    pthread_mutex_lock(&g_stateMutex);
    BOOL is1440 = g_isActual1440p;
    pthread_mutex_unlock(&g_stateMutex);
    return is1440;
}

NSString *InstagramDash1440p_GetCurrentQuality(void) {
    pthread_mutex_lock(&g_stateMutex);
    NSString *q = [g_currentQuality copy];
    pthread_mutex_unlock(&g_stateMutex);
    return q;
}

NSString *InstagramDash1440p_GetCurrentResolution(void) {
    pthread_mutex_lock(&g_stateMutex);
    NSString *r = [g_currentResolution copy];
    pthread_mutex_unlock(&g_stateMutex);
    return r;
}

NSString *InstagramDash1440p_GetCurrentRepresentationId(void) {
    pthread_mutex_lock(&g_stateMutex);
    NSString *repId = [g_currentRepresentationId copy];
    pthread_mutex_unlock(&g_stateMutex);
    return repId;
}

NSString *InstagramDash1440p_GetLogFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject ?: NSTemporaryDirectory();
    return [docDir stringByAppendingPathComponent:@"Instagram1440p.log"];
}

// ============================================================================
// Representation Introspection Helpers & Active Telemetry
// ============================================================================

static id ExtractRepresentationFromObject(id obj) {
    if (!obj) return nil;

    if ([obj respondsToSelector:@selector(representationId)] ||
        [obj respondsToSelector:@selector(videoSize)] ||
        [obj respondsToSelector:@selector(bandwidth)]) {
        return obj;
    }

    SEL selectors[] = {
        sel_registerName("selectedRepresentation"),
        sel_registerName("selectedRep"),
        sel_registerName("representation"),
        sel_registerName("videoRepresentation")
    };
    for (size_t i = 0; i < sizeof(selectors)/sizeof(selectors[0]); i++) {
        if ([obj respondsToSelector:selectors[i]]) {
            id inner = ((id (*)(id, SEL))objc_msgSend)(obj, selectors[i]);
            if (inner && inner != obj) {
                id extracted = ExtractRepresentationFromObject(inner);
                if (extracted) return extracted;
            }
        }
    }

    const char *keys[] = {"selectedRepresentation", "selectedRep", "representation", "videoRepresentation"};
    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
        @try {
            id inner = [obj valueForKey:[NSString stringWithUTF8String:keys[i]]];
            if (inner && inner != obj) {
                id extracted = ExtractRepresentationFromObject(inner);
                if (extracted) return extracted;
            }
        } @catch (NSException *e) {}
    }

    return obj;
}

static BOOL IsAudioRepresentation(id rep) {
    if (!rep) return NO;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual) actual = rep;

    if ([actual respondsToSelector:@selector(isAudio)]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(actual, @selector(isAudio))) return YES;
    }
    if ([actual respondsToSelector:@selector(track)]) {
        NSInteger tr = ((NSInteger (*)(id, SEL))objc_msgSend)(actual, @selector(track));
        if (tr == 1) return YES;
    }
    if ([actual respondsToSelector:@selector(representationId)]) {
        NSString *repId = ((NSString *(*)(id, SEL))objc_msgSend)(actual, @selector(representationId));
        if (repId && [repId hasSuffix:@"a"]) return YES;
    }
    return NO;
}

static CGSize GetRepresentationPixelDimensions(id rep) {
    if (!rep) return CGSizeZero;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual) actual = rep;

    CGSize sz = CGSizeZero;
    if ([actual respondsToSelector:@selector(videoSize)]) {
        sz = ((CGSize (*)(id, SEL))objc_msgSend)(actual, @selector(videoSize));
    }
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        CGFloat w = 0.0f, h = 0.0f;
        if ([actual respondsToSelector:@selector(videoWidth)]) {
            w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(actual, @selector(videoWidth));
        } else if ([actual respondsToSelector:@selector(width)]) {
            w = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(actual, @selector(width));
        }
        if ([actual respondsToSelector:@selector(videoHeight)]) {
            h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(actual, @selector(videoHeight));
        } else if ([actual respondsToSelector:@selector(height)]) {
            h = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(actual, @selector(height));
        }
        if (w > 0.0f && h > 0.0f) {
            sz = CGSizeMake(w, h);
        }
    }
    return sz;
}

static uint64_t GetRepresentationBitrate(id rep) {
    if (!rep) return 0;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual) actual = rep;

    if ([actual respondsToSelector:@selector(bandwidth)]) {
        return (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(actual, @selector(bandwidth));
    }
    if ([actual respondsToSelector:@selector(bitrate)]) {
        return (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(actual, @selector(bitrate));
    }
    return 0;
}

static NSString *GetRepresentationId(id rep) {
    if (!rep) return nil;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual) actual = rep;

    if ([actual respondsToSelector:@selector(representationId)]) {
        NSString *repId = ((NSString *(*)(id, SEL))objc_msgSend)(actual, @selector(representationId));
        if (repId && repId.length > 0) return repId;
    }
    if ([actual respondsToSelector:@selector(qualityLabel)]) {
        NSString *label = ((NSString *(*)(id, SEL))objc_msgSend)(actual, @selector(qualityLabel));
        if (label && label.length > 0) return label;
    }
    return nil;
}

static NSString *GetRepresentationEncodingTag(id rep) {
    if (!rep) return nil;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual) actual = rep;

    if ([actual respondsToSelector:@selector(encodingTag)]) {
        NSString *tag = ((NSString *(*)(id, SEL))objc_msgSend)(actual, @selector(encodingTag));
        if (tag && tag.length > 0) return tag;
    }
    return nil;
}

// ============================================================================
// Representation Metadata Cache & Active Reel Player Telemetry
// ============================================================================

static NSMutableDictionary *g_repMetadataCache = nil;
static pthread_mutex_t g_cacheMutex = PTHREAD_MUTEX_INITIALIZER;

static void CacheRepresentationMetadata(id rep) {
    if (!rep) return;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual || IsAudioRepresentation(actual)) return;

    NSString *repId = GetRepresentationId(actual);
    if (!repId || repId.length == 0) return;

    CGSize sz = GetRepresentationPixelDimensions(actual);
    NSString *tag = GetRepresentationEncodingTag(actual) ?: @"";
    uint64_t bw = GetRepresentationBitrate(actual);

    pthread_mutex_lock(&g_cacheMutex);
    if (!g_repMetadataCache) {
        g_repMetadataCache = [[NSMutableDictionary alloc] init];
    }
    g_repMetadataCache[repId] = @{
        @"width": @(sz.width),
        @"height": @(sz.height),
        @"tag": tag,
        @"bw": @(bw)
    };
    pthread_mutex_unlock(&g_cacheMutex);
}

static __weak id g_activePlayingPlayer = nil;
static pthread_mutex_t g_playerMutex = PTHREAD_MUTEX_INITIALIZER;

static void UpdateActivePlaybackTelemetryFromPlayer(id player, NSString *overrideRepId, NSString *overrideTag) {
    if (!player) return;

    BOOL isPlaying = NO;
    if ([player respondsToSelector:@selector(isPlaying)]) {
        @try {
            isPlaying = ((BOOL (*)(id, SEL))objc_msgSend)(player, @selector(isPlaying));
        } @catch (...) {}
    }

    BOOL isOnScreen = NO;
    if ([player respondsToSelector:@selector(videoView)]) {
        @try {
            UIView *vv = ((UIView * (*)(id, SEL))objc_msgSend)(player, @selector(videoView));
            if (vv && [vv isKindOfClass:[UIView class]] && vv.window != nil && !vv.hidden && vv.alpha > 0.01f) {
                isOnScreen = YES;
            }
        } @catch (...) {}
    }

    pthread_mutex_lock(&g_playerMutex);
    id active = g_activePlayingPlayer;

    if (isPlaying) {
        g_activePlayingPlayer = player;
    } else if (isOnScreen && active == player) {
        // Active visible paused reel; retain tracking
    } else {
        // Offscreen, prefetch, or idle player: reject
        pthread_mutex_unlock(&g_playerMutex);
        return;
    }
    pthread_mutex_unlock(&g_playerMutex);

    NSString *repId = overrideRepId;
    if (!repId || repId.length == 0) {
        if ([player respondsToSelector:@selector(currentRepresentationId)]) {
            @try {
                repId = ((NSString * (*)(id, SEL))objc_msgSend)(player, @selector(currentRepresentationId));
            } @catch (...) {}
        }
    }
    if (!repId || repId.length == 0) return;

    CGSize sz = CGSizeZero;
    if ([player respondsToSelector:@selector(currentVideoSize)]) {
        @try {
            sz = ((CGSize (*)(id, SEL))objc_msgSend)(player, @selector(currentVideoSize));
        } @catch (...) {}
    }

    NSString *tag = overrideTag;
    if (!tag && [player respondsToSelector:@selector(_currentVideoEncodingTag)]) {
        @try {
            tag = ((NSString * (*)(id, SEL))objc_msgSend)(player, @selector(_currentVideoEncodingTag));
        } @catch (...) {}
    }

    uint64_t bw = 0;
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        pthread_mutex_lock(&g_cacheMutex);
        NSDictionary *dict = g_repMetadataCache[repId];
        if (dict) {
            CGFloat w = [dict[@"width"] doubleValue];
            CGFloat h = [dict[@"height"] doubleValue];
            sz = CGSizeMake(w, h);
            if (!tag || tag.length == 0) {
                tag = dict[@"tag"];
            }
            bw = [dict[@"bw"] unsignedLongLongValue];
        }
        pthread_mutex_unlock(&g_cacheMutex);
    }

    CGFloat minDim = MIN(sz.width, sz.height);
    CGFloat maxDim = MAX(sz.width, sz.height);
    uint64_t pixels = (uint64_t)(sz.width * sz.height);

    BOOL is1440 = (minDim >= 1200.0f || maxDim >= 2200.0f || pixels >= 2800000ULL ||
                   (repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"968238693007748"] || [repId containsString:@"1440"] || [repId containsString:@"2k"])) ||
                   (tag && ([tag containsString:@"1440"] || [tag containsString:@"2k"])));

    BOOL is1080 = (!is1440 && (minDim >= 960.0f || maxDim >= 1700.0f || pixels >= 1600000ULL ||
                   (repId && [repId containsString:@"1080"]) ||
                   (tag && [tag containsString:@"1080"])));

    NSString *quality = is1440 ? @"1440p" : (is1080 ? @"1080p" : [NSString stringWithFormat:@"%.0fp", minDim > 0.0f ? minDim : 1080.0f]);
    NSString *resolution = (sz.width > 0.0f && sz.height > 0.0f) ? [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height] : (is1440 ? @"1440x2560" : @"1080x1920");

    BOOL changed = NO;
    pthread_mutex_lock(&g_stateMutex);
    if (g_isActual1440p != is1440 ||
        ![g_currentQuality isEqualToString:quality] ||
        ![g_currentResolution isEqualToString:resolution] ||
        ![g_currentRepresentationId isEqualToString:repId]) {
        g_isActual1440p = is1440;
        g_currentQuality = [quality copy];
        g_currentResolution = [resolution copy];
        g_currentRepresentationId = [repId copy];
        changed = YES;
    }
    pthread_mutex_unlock(&g_stateMutex);

    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
        });
    }
}

// ============================================================================
// Root-Level Manifest XML Pruning Engine
// ============================================================================

struct VideoRepInfo {
    NSRange range;
    uint32_t width;
    uint32_t height;
    uint64_t bandwidth;
    NSString *repId;
};

static id PruneManifestXml(id contentsOfXml) {
    if (!contentsOfXml) return nil;
    InstagramDash1440pMode mode = InstagramDash1440p_GetMode();
    if (mode == InstagramDash1440pModeDisabled) {
        return contentsOfXml;
    }

    @try {
        BOOL isData = [contentsOfXml isKindOfClass:[NSData class]];
        BOOL isString = [contentsOfXml isKindOfClass:[NSString class]];
        if (!isData && !isString) {
            return contentsOfXml;
        }

        NSString *xmlStr = nil;
        if (isData) {
            xmlStr = [[NSString alloc] initWithData:(NSData *)contentsOfXml encoding:NSUTF8StringEncoding];
        } else {
            xmlStr = (NSString *)contentsOfXml;
        }

        if (!xmlStr || xmlStr.length == 0 || [xmlStr rangeOfString:@"<Representation"].location == NSNotFound) {
            return contentsOfXml;
        }

        static NSRegularExpression *s_repRegex = nil;
        static NSRegularExpression *s_widthRegex = nil;
        static NSRegularExpression *s_heightRegex = nil;
        static NSRegularExpression *s_bwRegex = nil;
        static NSRegularExpression *s_idRegex = nil;
        static dispatch_once_t s_regexOnce;
        dispatch_once(&s_regexOnce, ^{
            s_repRegex = [[NSRegularExpression alloc] initWithPattern:@"<Representation\\b[\\s\\S]*?(?:/>|</Representation>)"
                                                              options:0
                                                                error:nil];
            s_widthRegex = [[NSRegularExpression alloc] initWithPattern:@"width=\"(\\d+)\"" options:0 error:nil];
            s_heightRegex = [[NSRegularExpression alloc] initWithPattern:@"height=\"(\\d+)\"" options:0 error:nil];
            s_bwRegex = [[NSRegularExpression alloc] initWithPattern:@"bandwidth=\"(\\d+)\"" options:0 error:nil];
            s_idRegex = [[NSRegularExpression alloc] initWithPattern:@"id=\"([^\"]+)\"" options:0 error:nil];
        });

        NSArray<NSTextCheckingResult *> *matches = [s_repRegex matchesInString:xmlStr options:0 range:NSMakeRange(0, xmlStr.length)];
        if (!matches || matches.count <= 1) {
            return contentsOfXml;
        }

        std::vector<VideoRepInfo> videoReps;
        BOOL isCellular = InstagramWifiSpoofer_IsCellularData();

        for (NSTextCheckingResult *match in matches) {
            NSRange repRange = match.range;
            NSString *repBlock = [xmlStr substringWithRange:repRange];

            // Filter out audio representations by AdaptationSet context
            NSRange beforeRange = NSMakeRange(0, repRange.location);
            NSRange lastAdaptationSet = [xmlStr rangeOfString:@"<AdaptationSet" options:NSBackwardsSearch range:beforeRange];
            if (lastAdaptationSet.location != NSNotFound) {
                NSRange adaptHeaderRange = NSMakeRange(lastAdaptationSet.location, MIN((NSUInteger)300, xmlStr.length - lastAdaptationSet.location));
                NSString *adaptHeader = [xmlStr substringWithRange:adaptHeaderRange];
                if ([adaptHeader rangeOfString:@"audio"].location != NSNotFound) {
                    continue;
                }
            }

            // Direct block audio check
            if ([repBlock rangeOfString:@"mimeType=\"audio"].location != NSNotFound ||
                [repBlock rangeOfString:@"audioSamplingRate"].location != NSNotFound ||
                [repBlock rangeOfString:@"codecs=\"mp4a"].location != NSNotFound) {
                continue;
            }

            uint32_t w = 0, h = 0;
            uint64_t bw = 0;
            NSString *repId = @"";

            NSTextCheckingResult *wMatch = [s_widthRegex firstMatchInString:repBlock options:0 range:NSMakeRange(0, repBlock.length)];
            if (wMatch && wMatch.numberOfRanges > 1) {
                w = (uint32_t)[[repBlock substringWithRange:[wMatch rangeAtIndex:1]] intValue];
            }

            NSTextCheckingResult *hMatch = [s_heightRegex firstMatchInString:repBlock options:0 range:NSMakeRange(0, repBlock.length)];
            if (hMatch && hMatch.numberOfRanges > 1) {
                h = (uint32_t)[[repBlock substringWithRange:[hMatch rangeAtIndex:1]] intValue];
            }

            NSTextCheckingResult *bwMatch = [s_bwRegex firstMatchInString:repBlock options:0 range:NSMakeRange(0, repBlock.length)];
            if (bwMatch && bwMatch.numberOfRanges > 1) {
                bw = (uint64_t)[[repBlock substringWithRange:[bwMatch rangeAtIndex:1]] longLongValue];
            }

            NSTextCheckingResult *idMatch = [s_idRegex firstMatchInString:repBlock options:0 range:NSMakeRange(0, repBlock.length)];
            if (idMatch && idMatch.numberOfRanges > 1) {
                repId = [repBlock substringWithRange:[idMatch rangeAtIndex:1]];
            }

            if (w > 0 || h > 0 || [repBlock rangeOfString:@"video/"].location != NSNotFound) {
                VideoRepInfo info;
                info.range = repRange;
                info.width = w;
                info.height = h;
                info.bandwidth = bw;
                info.repId = repId;
                videoReps.push_back(info);
            }
        }

        if (videoReps.size() <= 1) {
            return contentsOfXml;
        }

        int targetIdx = -1;
        BOOL has1440 = NO;
        BOOL has1080 = NO;

        for (size_t i = 0; i < videoReps.size(); i++) {
            uint32_t w = videoReps[i].width;
            uint32_t h = videoReps[i].height;
            uint64_t pixels = (uint64_t)w * h;
            NSString *rid = videoReps[i].repId;
            if (w >= 1200 || h >= 2200 || pixels >= 2800000ULL ||
                (rid && ([rid containsString:@"1440"] || [rid containsString:@"2k"] || [rid containsString:@"1539525017490074"] || [rid containsString:@"968238693007748"]))) {
                has1440 = YES;
            }
            if (w >= 960 || h >= 1700 || pixels >= 1600000ULL || (rid && [rid containsString:@"1080"])) {
                has1080 = YES;
            }
        }

        if (mode == InstagramDash1440pModeWifiOnly && isCellular) {
            // Mode 1 on Cellular: Cap to 1080p
            uint64_t bestMetric = 0;
            for (size_t i = 0; i < videoReps.size(); i++) {
                uint32_t w = videoReps[i].width;
                uint32_t h = videoReps[i].height;
                uint64_t pixels = (uint64_t)w * h;
                NSString *rid = videoReps[i].repId;
                BOOL is1440 = (w >= 1200 || h >= 2200 || pixels >= 2800000ULL || (rid && ([rid containsString:@"1440"] || [rid containsString:@"2k"])));
                if (!is1440) {
                    uint64_t metric = pixels * 10000000ULL + videoReps[i].bandwidth;
                    if (targetIdx == -1 || metric > bestMetric) {
                        bestMetric = metric;
                        targetIdx = (int)i;
                    }
                }
            }
        } else {
            // Mode 1 on Wi-Fi OR Mode 2 (Always 1440p): 1440p Priority, 1080p Fallback Floor
            if (has1440) {
                uint64_t bestBw = 0;
                for (size_t i = 0; i < videoReps.size(); i++) {
                    uint32_t w = videoReps[i].width;
                    uint32_t h = videoReps[i].height;
                    uint64_t pixels = (uint64_t)w * h;
                    NSString *rid = videoReps[i].repId;
                    BOOL is1440 = (w >= 1200 || h >= 2200 || pixels >= 2800000ULL || (rid && ([rid containsString:@"1440"] || [rid containsString:@"2k"])));
                    if (is1440) {
                        if (targetIdx == -1 || videoReps[i].bandwidth > bestBw) {
                            bestBw = videoReps[i].bandwidth;
                            targetIdx = (int)i;
                        }
                    }
                }
            } else if (has1080) {
                uint64_t bestBw = 0;
                for (size_t i = 0; i < videoReps.size(); i++) {
                    uint32_t w = videoReps[i].width;
                    uint32_t h = videoReps[i].height;
                    uint64_t pixels = (uint64_t)w * h;
                    NSString *rid = videoReps[i].repId;
                    BOOL is1080 = (w >= 960 || h >= 1700 || pixels >= 1600000ULL || (rid && [rid containsString:@"1080"]));
                    if (is1080) {
                        if (targetIdx == -1 || videoReps[i].bandwidth > bestBw) {
                            bestBw = videoReps[i].bandwidth;
                            targetIdx = (int)i;
                        }
                    }
                }
            }
        }

        if (targetIdx == -1) {
            targetIdx = 0;
        }

        NSMutableString *prunedStr = [xmlStr mutableCopy];
        for (int i = (int)videoReps.size() - 1; i >= 0; i--) {
            if (i != targetIdx) {
                NSRange r = videoReps[i].range;
                while (r.location > 0 && ([prunedStr characterAtIndex:r.location - 1] == ' ' || [prunedStr characterAtIndex:r.location - 1] == '\t')) {
                    r.location--;
                    r.length++;
                }
                if (r.location > 0 && [prunedStr characterAtIndex:r.location - 1] == '\n') {
                    r.location--;
                    r.length++;
                }
                [prunedStr deleteCharactersInRange:r];
            }
        }

        if (isData) {
            return [prunedStr dataUsingEncoding:NSUTF8StringEncoding];
        }
        return [prunedStr copy];
    } @catch (NSException *ex) {
        return contentsOfXml;
    }
}

// ============================================================================
// Objective-C Swizzle Helpers
// ============================================================================

static BOOL SafeSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;

    if (origImp && !*origImp) {
        *origImp = orig;
    }

    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }
    return YES;
}

static BOOL SafeSwizzleClassMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return NO;
    Class metaCls = object_getClass((id)cls);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;

    if (origImp && !*origImp) {
        *origImp = orig;
    }

    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(metaCls, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }
    return YES;
}

// ============================================================================
// Root Manifest Ingestion Swizzles
// ============================================================================

// FNFMediaPresentationDescription Factory Hooks
static id (*orig_presDesc_xml_config)(id self, SEL _cmd, id contentsOfXml, id mpdUrl, id config, id mpdConfig, id source, NSError **error) = NULL;
static id Hook_PresDesc_WithContentsOfXml_Config(id self, SEL _cmd, id contentsOfXml, id mpdUrl, id config, id mpdConfig, id source, NSError **error) {
    id pruned = PruneManifestXml(contentsOfXml);
    if (orig_presDesc_xml_config) {
        return orig_presDesc_xml_config(self, _cmd, pruned ? pruned : contentsOfXml, mpdUrl, config, mpdConfig, source, error);
    }
    return nil;
}

static id (*orig_presDesc_xml_error)(id self, SEL _cmd, id contentsOfXml, id mpdUrl, NSError **error) = NULL;
static id Hook_PresDesc_WithContentsOfXml_Error(id self, SEL _cmd, id contentsOfXml, id mpdUrl, NSError **error) {
    id pruned = PruneManifestXml(contentsOfXml);
    if (orig_presDesc_xml_error) {
        return orig_presDesc_xml_error(self, _cmd, pruned ? pruned : contentsOfXml, mpdUrl, error);
    }
    return nil;
}

static id (*orig_presDesc_xml_curTime)(id self, SEL _cmd, id contentsOfXml, id mpdUrl, id config, id mpdConfig, id source, id currentTime, NSError **error) = NULL;
static id Hook_PresDesc_WithContentsOfXml_CurTime(id self, SEL _cmd, id contentsOfXml, id mpdUrl, id config, id mpdConfig, id source, id currentTime, NSError **error) {
    id pruned = PruneManifestXml(contentsOfXml);
    if (orig_presDesc_xml_curTime) {
        return orig_presDesc_xml_curTime(self, _cmd, pruned ? pruned : contentsOfXml, mpdUrl, config, mpdConfig, source, currentTime, error);
    }
    return nil;
}

// IGVideo Inlined Manifest Accessor Hooks
static NSData * (*orig_video_dashManifest)(id self, SEL _cmd) = NULL;
static NSData * Hook_IGVideo_DashManifest(id self, SEL _cmd) {
    NSData *orig = orig_video_dashManifest ? orig_video_dashManifest(self, _cmd) : nil;
    if (!orig) return nil;
    return (NSData *)PruneManifestXml(orig);
}

static NSData * (*orig_video_dashManifestData)(id self, SEL _cmd) = NULL;
static NSData * Hook_IGVideo_DashManifestData(id self, SEL _cmd) {
    NSData *orig = orig_video_dashManifestData ? orig_video_dashManifestData(self, _cmd) : nil;
    if (!orig) return nil;
    return (NSData *)PruneManifestXml(orig);
}

// ============================================================================
// Hardware VP9 Decoding via VideoToolbox
// ============================================================================

typedef struct OpaqueVTDecompressionSession* VTDecompressionSessionRef;

static OSStatus (*orig_VTDecompressionSessionCreate)(
    CFAllocatorRef allocator,
    CMVideoFormatDescriptionRef videoFormatDescription,
    CFDictionaryRef videoDecoderSpecification,
    CFDictionaryRef destinationImageBufferAttributes,
    const void *outputCallback,
    VTDecompressionSessionRef *decompressionSessionOut) = NULL;

static OSStatus Hook_VTDecompressionSessionCreate(
    CFAllocatorRef allocator,
    CMVideoFormatDescriptionRef videoFormatDescription,
    CFDictionaryRef videoDecoderSpecification,
    CFDictionaryRef destinationImageBufferAttributes,
    const void *outputCallback,
    VTDecompressionSessionRef *decompressionSessionOut) {

    CFMutableDictionaryRef decoderSpec = NULL;
    if (videoDecoderSpecification) {
        decoderSpec = CFDictionaryCreateMutableCopy(allocator, 0, videoDecoderSpecification);
    } else {
        decoderSpec = CFDictionaryCreateMutable(allocator, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }

    if (decoderSpec) {
        CFDictionarySetValue(decoderSpec, CFSTR("EnableHardwareAcceleratedVideoDecoder"), kCFBooleanTrue);
    }

    OSStatus status = noErr;
    if (orig_VTDecompressionSessionCreate) {
        status = orig_VTDecompressionSessionCreate(
            allocator,
            videoFormatDescription,
            decoderSpec ? decoderSpec : videoDecoderSpecification,
            destinationImageBufferAttributes,
            outputCallback,
            decompressionSessionOut);
    }

    if (decoderSpec) {
        CFRelease(decoderSpec);
    }

    if (status == noErr && decompressionSessionOut && *decompressionSessionOut) {
        typedef OSStatus (*VTSessionSetPropertyFunc)(VTDecompressionSessionRef, CFStringRef, CFTypeRef);
        static VTSessionSetPropertyFunc s_setPropFunc = NULL;
        static dispatch_once_t propOnce;
        dispatch_once(&propOnce, ^{
            s_setPropFunc = (VTSessionSetPropertyFunc)dlsym(RTLD_DEFAULT, "VTSessionSetProperty");
        });

        if (s_setPropFunc) {
            s_setPropFunc(*decompressionSessionOut, CFSTR("RealTime"), kCFBooleanTrue);
        }
    }

    return status;
}

static void HookVTDecompressionSessionCreateOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct rebinding rebindings[] = {
            {
                "VTDecompressionSessionCreate",
                (void *)Hook_VTDecompressionSessionCreate,
                (void **)&orig_VTDecompressionSessionCreate
            }
        };
        rebind_symbols(rebindings, 1);
    });
}

// FNFDecompressionSessionForVP9X
static id (*orig_vp9x_init)(id self, SEL _cmd, id delegate, void *formatDesc, CGSize videoSize, BOOL async, void *config, id pcm, NSError **error) = NULL;

static id Hook_FNFDecompressionSessionForVP9X_Init(id self, SEL _cmd, id delegate, void *formatDesc, CGSize videoSize, BOOL async, void *config, id pcm, NSError **error) {
    if (config) {
        uint8_t *cfg = (uint8_t *)config;
        cfg[0x59] = 1; // enableVTForVP9
        cfg[0x58] = 1; // enableVTHWAcceleratedDetection
        cfg[0x74] = 1; // fixVP9DecoderRegistrationRace
        cfg[0x38] = 0; // enableVP9VTDecodingDimensionCheck
        cfg[0x33] = 0; // disableVTAsynchronousDecompression
        cfg[0x34] = 0; // disableVT1xRealTimePlayback
        cfg[0x35] = 0; // disableVTTemporalProcessing
    }

    if (orig_vp9x_init) {
        return orig_vp9x_init(self, _cmd, delegate, formatDesc, videoSize, async, config, pcm, error);
    }
    return nil;
}

static BOOL (*orig_vp9x_usesSoftwareDecoder)(id self, SEL _cmd) = NULL;
static BOOL Hook_FNFDecompressionSessionForVP9X_UsesSoftwareDecoder(id self, SEL _cmd) {
    return NO;
}

// ============================================================================
// IGFNFVideoPlayer Hooks: Strictly Track Currently Playing On-Screen Reel
// ============================================================================

static void (*orig_FNFVideoPlayer_stateManagerTransitionToVideoStartedPlaying)(id self, SEL _cmd) = NULL;
static void Hook_FNFVideoPlayer_StateManagerTransitionToVideoStartedPlaying(id self, SEL _cmd) {
    if (orig_FNFVideoPlayer_stateManagerTransitionToVideoStartedPlaying) {
        orig_FNFVideoPlayer_stateManagerTransitionToVideoStartedPlaying(self, _cmd);
    }
    UpdateActivePlaybackTelemetryFromPlayer(self, nil, nil);
}

static void (*orig_FNFVideoPlayer_videoRepresentationIdChanged)(id self, SEL _cmd, id repId, id codec, id encodingTag, id audioRoleMetadata) = NULL;
static void Hook_FNFVideoPlayer_VideoRepresentationIdChanged(id self, SEL _cmd, id repId, id codec, id encodingTag, id audioRoleMetadata) {
    if (orig_FNFVideoPlayer_videoRepresentationIdChanged) {
        orig_FNFVideoPlayer_videoRepresentationIdChanged(self, _cmd, repId, codec, encodingTag, audioRoleMetadata);
    }
    NSString *repIdStr = [repId isKindOfClass:[NSString class]] ? repId : (repId ? [NSString stringWithFormat:@"%@", repId] : nil);
    NSString *tagStr = [encodingTag isKindOfClass:[NSString class]] ? encodingTag : (encodingTag ? [NSString stringWithFormat:@"%@", encodingTag] : nil);
    UpdateActivePlaybackTelemetryFromPlayer(self, repIdStr, tagStr);
}

static void (*orig_FNFVideoPlayer_playWithReason)(id self, SEL _cmd, NSInteger reason, id callsite) = NULL;
static void Hook_FNFVideoPlayer_PlayWithReason(id self, SEL _cmd, NSInteger reason, id callsite) {
    if (orig_FNFVideoPlayer_playWithReason) {
        orig_FNFVideoPlayer_playWithReason(self, _cmd, reason, callsite);
    }
    UpdateActivePlaybackTelemetryFromPlayer(self, nil, nil);
}

// ============================================================================
// Swizzle Registration & Initialization
// ============================================================================

static void SwizzleDashClasses(void) {
    // 1. Root Manifest Parser Hooks on FNFMediaPresentationDescription
    Class presDescCls = objc_getClass("FNFMediaPresentationDescription");
    if (presDescCls) {
        SEL sel1 = sel_registerName("presentationDescriptionWithContentsOfXml:mpdUrl:config:mpdConfig:source:error:");
        SafeSwizzleClassMethod(presDescCls, sel1, (IMP)Hook_PresDesc_WithContentsOfXml_Config, (IMP *)&orig_presDesc_xml_config);
        SafeSwizzleMethod(presDescCls, sel1, (IMP)Hook_PresDesc_WithContentsOfXml_Config, (IMP *)&orig_presDesc_xml_config);

        SEL sel2 = sel_registerName("presentationDescriptionWithContentsOfXml:mpdUrl:error:");
        SafeSwizzleClassMethod(presDescCls, sel2, (IMP)Hook_PresDesc_WithContentsOfXml_Error, (IMP *)&orig_presDesc_xml_error);
        SafeSwizzleMethod(presDescCls, sel2, (IMP)Hook_PresDesc_WithContentsOfXml_Error, (IMP *)&orig_presDesc_xml_error);

        SEL sel3 = sel_registerName("_presentationDescriptionWithContentsOfXml:mpdUrl:config:mpdConfig:source:currentTime:error:");
        SafeSwizzleClassMethod(presDescCls, sel3, (IMP)Hook_PresDesc_WithContentsOfXml_CurTime, (IMP *)&orig_presDesc_xml_curTime);
        SafeSwizzleMethod(presDescCls, sel3, (IMP)Hook_PresDesc_WithContentsOfXml_CurTime, (IMP *)&orig_presDesc_xml_curTime);
    }

    // 2. Inlined Manifest Accessors on IGVideo
    Class videoCls = objc_getClass("IGVideo");
    if (videoCls) {
        SafeSwizzleMethod(videoCls, sel_registerName("dashManifest"),
                          (IMP)Hook_IGVideo_DashManifest, (IMP *)&orig_video_dashManifest);
        SafeSwizzleMethod(videoCls, sel_registerName("dashManifestData"),
                          (IMP)Hook_IGVideo_DashManifestData, (IMP *)&orig_video_dashManifestData);
    }

    // 3. Apple VideoToolbox Hardware VP9 Decoder
    Class vp9xCls = objc_getClass("FNFDecompressionSessionForVP9X");
    if (vp9xCls) {
        SafeSwizzleMethod(vp9xCls,
                          sel_registerName("initWithDelegate:sampleBufferFormatDescription:videoSize:async:config:playerConfigManager:error:"),
                          (IMP)Hook_FNFDecompressionSessionForVP9X_Init,
                          (IMP *)&orig_vp9x_init);
        SafeSwizzleMethod(vp9xCls,
                          sel_registerName("usesSoftwareDecoder"),
                          (IMP)Hook_FNFDecompressionSessionForVP9X_UsesSoftwareDecoder,
                          (IMP *)&orig_vp9x_usesSoftwareDecoder);
    }

    // 4. Active On-Screen Reel Video Player Telemetry
    Class videoPlayerCls = objc_getClass("IGFNFVideoPlayer");
    if (videoPlayerCls) {
        SafeSwizzleMethod(videoPlayerCls, sel_registerName("_stateManagerTransitionToVideoStartedPlaying"),
                          (IMP)Hook_FNFVideoPlayer_StateManagerTransitionToVideoStartedPlaying,
                          (IMP *)&orig_FNFVideoPlayer_stateManagerTransitionToVideoStartedPlaying);
        SafeSwizzleMethod(videoPlayerCls, sel_registerName("videoRepresentationIdChanged:codec:encodingTag:audioRoleMetadata:"),
                          (IMP)Hook_FNFVideoPlayer_VideoRepresentationIdChanged,
                          (IMP *)&orig_FNFVideoPlayer_videoRepresentationIdChanged);
        SafeSwizzleMethod(videoPlayerCls, sel_registerName("playWithReason:callsiteContext:"),
                          (IMP)Hook_FNFVideoPlayer_PlayWithReason,
                          (IMP *)&orig_FNFVideoPlayer_playWithReason);
    }
}

static void ApplyAllDash1440pSwizzles(void) {
    static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_mutex);
    SwizzleDashClasses();
    pthread_mutex_unlock(&s_mutex);
}

void InstagramDash1440p_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        HookVTDecompressionSessionCreateOnce();
        ApplyAllDash1440pSwizzles();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                           object:nil
                                                            queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification * _Nonnull note) {
            ApplyAllDash1440pSwizzles();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApplyAllDash1440pSwizzles();
        });
    });
}

__attribute__((constructor))
static void InstagramDash1440pAutoInit(void) {
    InstagramDash1440p_Init();
}
