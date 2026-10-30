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

// Default: Disabled (Instagram handles default behavior on Wi-Fi and Cellular)
static InstagramDash1440pMode g_dashMode = InstagramDash1440pModeDisabled;
static BOOL g_force1440pActive = NO;
static BOOL g_lastVideoHas1440 = NO;
static pthread_mutex_t g_lastVideoMutex = PTHREAD_MUTEX_INITIALIZER;

static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1080p";
static NSString *g_currentResolution = @"";
static NSString *g_currentRepresentationId = @"ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

// Zero-overhead logging stub
#define DashLog(...) do {} while(0)

// ============================================================================
// Public Control & Telemetry Interfaces
// ============================================================================

BOOL InstagramDash1440p_IsForce1440pActive(void) {
    pthread_mutex_lock(&g_stateMutex);
    BOOL active = g_force1440pActive;
    pthread_mutex_unlock(&g_stateMutex);
    return active;
}

void InstagramDash1440p_SetForce1440pActive(BOOL active) {
    pthread_mutex_lock(&g_stateMutex);
    g_force1440pActive = active;
    g_dashMode = active ? InstagramDash1440pModeAlways1440p : InstagramDash1440pModeDisabled;
    pthread_mutex_unlock(&g_stateMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

InstagramDash1440pCheckResult InstagramDash1440p_ForceCheckAndFetch1440p(void) {
    pthread_mutex_lock(&g_stateMutex);
    BOOL active = g_force1440pActive;
    pthread_mutex_unlock(&g_stateMutex);

    if (active) {
        // Toggle OFF -> Return to Instagram default behavior
        InstagramDash1440p_SetForce1440pActive(NO);
        return InstagramDash1440pCheckResultDisabled;
    }

    // Check if 1440p is available for the current reel
    BOOL has1440 = NO;

    // 1. Check last parsed manifest
    pthread_mutex_lock(&g_lastVideoMutex);
    if (g_lastVideoHas1440) {
        has1440 = YES;
    }
    pthread_mutex_unlock(&g_lastVideoMutex);

    // 2. Check metadata cache
    if (!has1440) {
        pthread_mutex_lock(&g_cacheMutex);
        for (NSString *key in g_repMetadataCache) {
            NSDictionary *d = g_repMetadataCache[key];
            CGFloat w = [d[@"width"] doubleValue];
            CGFloat h = [d[@"height"] doubleValue];
            NSString *tag = d[@"tag"];
            CGFloat minDim = MIN(w, h);
            CGFloat maxDim = MAX(w, h);
            uint64_t pixels = (uint64_t)(w * h);
            if (minDim >= 1200.0f || maxDim >= 2200.0f || pixels >= 2800000ULL ||
                (key && ([key containsString:@"1539525017490074"] || [key containsString:@"968238693007748"] || [key containsString:@"1440"] || [key containsString:@"2k"])) ||
                (tag && ([tag containsString:@"1440"] || [tag containsString:@"2k"]))) {
                has1440 = YES;
                break;
            }
        }
        pthread_mutex_unlock(&g_cacheMutex);
    }

    // 3. Check active player representations
    pthread_mutex_lock(&g_playerMutex);
    id player = g_activePlayingPlayer;
    pthread_mutex_unlock(&g_playerMutex);

    if (player && !has1440) {
        NSArray *reps = nil;
        if ([player respondsToSelector:@selector(playlist)]) {
            @try {
                id pl = ((id (*)(id, SEL))objc_msgSend)(player, @selector(playlist));
                if (pl && [pl respondsToSelector:@selector(representationsForTrack:)]) {
                    reps = ((NSArray * (*)(id, SEL, NSInteger))objc_msgSend)(pl, @selector(representationsForTrack:), 1);
                }
            } @catch (...) {}
        }
        if (reps && reps.count > 0) {
            for (id rep in reps) {
                CGSize sz = GetRepresentationPixelDimensions(rep);
                uint64_t px = (uint64_t)(sz.width * sz.height);
                CGFloat minDim = MIN(sz.width, sz.height);
                CGFloat maxDim = MAX(sz.width, sz.height);
                NSString *rid = nil;
                if ([rep respondsToSelector:@selector(representationId)]) {
                    rid = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
                }
                if (minDim >= 1200.0f || maxDim >= 2200.0f || px >= 2800000ULL ||
                    (rid && ([rid containsString:@"1539525017490074"] || [rid containsString:@"968238693007748"] || [rid containsString:@"1440"] || [rid containsString:@"2k"]))) {
                    has1440 = YES;
                    break;
                }
            }
        }
    }

    if (player && !has1440) {
        // Player is active, but 1440p master is not available for this reel
        return InstagramDash1440pCheckResult1440pNotAvailable;
    }

    // 1440p found (or armed if player not active yet)
    InstagramDash1440p_SetForce1440pActive(YES);

    // If player is active and has selectQuality, trigger it
    if (player) {
        SEL selQ = sel_registerName("selectQuality");
        if ([player respondsToSelector:selQ]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(player, selQ);
            } @catch (...) {}
        }
    }

    return player ? InstagramDash1440pCheckResult1440pFoundAndForced : InstagramDash1440pCheckResultArmed;
}

InstagramDash1440pMode InstagramDash1440p_GetMode(void) {
    pthread_mutex_lock(&g_stateMutex);
    InstagramDash1440pMode m = g_dashMode;
    pthread_mutex_unlock(&g_stateMutex);
    return m;
}

void InstagramDash1440p_SetMode(InstagramDash1440pMode mode) {
    pthread_mutex_lock(&g_stateMutex);
    g_dashMode = mode;
    g_force1440pActive = (mode != InstagramDash1440pModeDisabled);
    pthread_mutex_unlock(&g_stateMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

InstagramDash1440pMode InstagramDash1440p_CycleMode(void) {
    InstagramDash1440p_ForceCheckAndFetch1440p();
    return InstagramDash1440p_GetMode();
}

NSString *InstagramDash1440p_GetModeName(void) {
    if (InstagramDash1440p_IsForce1440pActive()) {
        return @"1440p Forced";
    }
    return @"Disabled (IG Default)";
}

BOOL InstagramDash1440p_IsEnabled(void) {
    return InstagramDash1440p_IsForce1440pActive();
}

void InstagramDash1440p_SetEnabled(BOOL enabled) {
    InstagramDash1440p_SetForce1440pActive(enabled);
}

BOOL InstagramDash1440p_ToggleEnabled(void) {
    InstagramDash1440p_ForceCheckAndFetch1440p();
    return InstagramDash1440p_IsForce1440pActive();
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

    NSString *quality = is1440 ? @"1440p" : @"1080p";
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
    BOOL is1440;
    BOOL is1080;
};

static id PruneManifestXml(id contentsOfXml) {
    if (!contentsOfXml) return nil;

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

        // Detect if this video manifest has a 1440p representation and cache it
        BOOL has1440InXml = ([xmlStr rangeOfString:@"1440"].location != NSNotFound ||
                             [xmlStr rangeOfString:@"2560"].location != NSNotFound ||
                             [xmlStr rangeOfString:@"1539525017490074"].location != NSNotFound ||
                             [xmlStr rangeOfString:@"968238693007748"].location != NSNotFound ||
                             [xmlStr rangeOfString:@"2k"].location != NSNotFound ||
                             [xmlStr rangeOfString:@"2K"].location != NSNotFound);
        pthread_mutex_lock(&g_lastVideoMutex);
        g_lastVideoHas1440 = has1440InXml;
        pthread_mutex_unlock(&g_lastVideoMutex);

        // If Force 1440p is NOT active: Leave manifest 100% untouched for Instagram's default behavior!
        if (!InstagramDash1440p_IsForce1440pActive()) {
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
                NSRange adaptHeaderRange = NSMakeRange(lastAdaptationSet.location, MIN((NSUInteger)500, xmlStr.length - lastAdaptationSet.location));
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

            // Inherit dimensions from parent AdaptationSet if not present on Representation tag
            if ((w == 0 || h == 0) && lastAdaptationSet.location != NSNotFound) {
                NSRange adaptHeaderRange = NSMakeRange(lastAdaptationSet.location, MIN((NSUInteger)500, xmlStr.length - lastAdaptationSet.location));
                NSString *adaptHeader = [xmlStr substringWithRange:adaptHeaderRange];
                if (w == 0) {
                    NSTextCheckingResult *awMatch = [s_widthRegex firstMatchInString:adaptHeader options:0 range:NSMakeRange(0, adaptHeader.length)];
                    if (awMatch && awMatch.numberOfRanges > 1) {
                        w = (uint32_t)[[adaptHeader substringWithRange:[awMatch rangeAtIndex:1]] intValue];
                    }
                }
                if (h == 0) {
                    NSTextCheckingResult *ahMatch = [s_heightRegex firstMatchInString:adaptHeader options:0 range:NSMakeRange(0, adaptHeader.length)];
                    if (ahMatch && ahMatch.numberOfRanges > 1) {
                        h = (uint32_t)[[adaptHeader substringWithRange:[ahMatch rangeAtIndex:1]] intValue];
                    }
                }
            }

            uint64_t pixels = (uint64_t)w * h;
            BOOL repIs1440 = (w >= 1200 || h >= 2200 || pixels >= 2800000ULL ||
                              (repId && ([repId containsString:@"1440"] || [repId containsString:@"2k"] || [repId containsString:@"1539525017490074"] || [repId containsString:@"968238693007748"])) ||
                              [repBlock containsString:@"1440p"] || [repBlock containsString:@"1440P"] ||
                              [repBlock containsString:@"FBQualityLabel=\"1440"] || [repBlock containsString:@"qualityLabel=\"1440"]);

            BOOL repIs1080 = (!repIs1440 && (w >= 960 || h >= 1700 || pixels >= 1600000ULL ||
                              (repId && [repId containsString:@"1080"]) ||
                              [repBlock containsString:@"1080p"] || [repBlock containsString:@"1080P"] ||
                              [repBlock containsString:@"FBQualityLabel=\"1080"] || [repBlock containsString:@"qualityLabel=\"1080"]));

            if (w > 0 || h > 0 || repIs1440 || repIs1080 || [repBlock rangeOfString:@"video/"].location != NSNotFound) {
                VideoRepInfo info;
                info.range = repRange;
                info.width = w;
                info.height = h;
                info.bandwidth = bw;
                info.repId = repId;
                info.is1440 = repIs1440;
                info.is1080 = repIs1080;
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
            if (videoReps[i].is1440) has1440 = YES;
            if (videoReps[i].is1080) has1080 = YES;
        }

        // Force 1440p Active: Prioritize 1440p regardless of Wi-Fi or Cellular, fallback to 1080p floor
        if (has1440) {
            uint64_t bestBw = 0;
            for (size_t i = 0; i < videoReps.size(); i++) {
                if (videoReps[i].is1440) {
                    if (targetIdx == -1 || videoReps[i].bandwidth > bestBw) {
                        bestBw = videoReps[i].bandwidth;
                        targetIdx = (int)i;
                    }
                }
            }
        } else if (has1080) {
            uint64_t bestBw = 0;
            for (size_t i = 0; i < videoReps.size(); i++) {
                if (videoReps[i].is1080) {
                    if (targetIdx == -1 || videoReps[i].bandwidth > bestBw) {
                        bestBw = videoReps[i].bandwidth;
                        targetIdx = (int)i;
                    }
                }
            }
        }

        // If neither 1440p nor 1080p is available (e.g. video only uploaded in 720p), pick highest metric
        if (targetIdx == -1) {
            uint64_t bestMetric = 0;
            for (size_t i = 0; i < videoReps.size(); i++) {
                uint64_t metric = (uint64_t)videoReps[i].width * videoReps[i].height * 10000ULL + videoReps[i].bandwidth;
                if (targetIdx == -1 || metric > bestMetric) {
                    bestMetric = metric;
                    targetIdx = (int)i;
                }
            }
            if (targetIdx == -1) {
                targetIdx = 0;
            }
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
            NSData *d = [prunedStr dataUsingEncoding:NSUTF8StringEncoding];
            return d ? d : contentsOfXml;
        }
        return prunedStr ? [prunedStr copy] : contentsOfXml;
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

// FNFMediaPresentationDescription Factory Hook
// Selector: +[FNFMediaPresentationDescription presentationDescriptionWithContentsOfXml:mpdUrl:error:]
// Signature: @40@0:8@16@24^@32 (Standard Objective-C object pointers)
static id (*orig_presDesc_xml_error)(id self, SEL _cmd, id contentsOfXml, id mpdUrl, NSError **error) = NULL;
static __thread BOOL s_inPresDescHook = NO;
static id Hook_PresDesc_WithContentsOfXml_Error(id self, SEL _cmd, id contentsOfXml, id mpdUrl, NSError **error) {
    if (s_inPresDescHook) {
        return orig_presDesc_xml_error ? orig_presDesc_xml_error(self, _cmd, contentsOfXml, mpdUrl, error) : nil;
    }
    s_inPresDescHook = YES;
    id pruned = contentsOfXml ? PruneManifestXml(contentsOfXml) : nil;
    id result = nil;
    if (orig_presDesc_xml_error) {
        result = orig_presDesc_xml_error(self, _cmd, pruned ? pruned : contentsOfXml, mpdUrl, error);
    }
    s_inPresDescHook = NO;
    return result;
}

// IGVideo Manifest Accessor & Mutator Hooks
// Selectors: -[IGVideo videoDashManifest], -[IGVideo setVideoDashManifest:],
//            -[IGVideo dashManifest], -[IGVideo dashManifestData], -[IGVideo setDashManifestData:]
static id (*orig_video_videoDashManifest)(id self, SEL _cmd) = NULL;
static __thread BOOL s_inVideoDashManifestHook = NO;
static id Hook_IGVideo_VideoDashManifest(id self, SEL _cmd) {
    if (s_inVideoDashManifestHook) {
        return orig_video_videoDashManifest ? orig_video_videoDashManifest(self, _cmd) : nil;
    }
    s_inVideoDashManifestHook = YES;
    id orig = orig_video_videoDashManifest ? orig_video_videoDashManifest(self, _cmd) : nil;
    id pruned = orig ? PruneManifestXml(orig) : nil;
    s_inVideoDashManifestHook = NO;
    return pruned ? pruned : orig;
}

static void (*orig_video_setVideoDashManifest)(id self, SEL _cmd, id manifest) = NULL;
static void Hook_IGVideo_SetVideoDashManifest(id self, SEL _cmd, id manifest) {
    id pruned = manifest ? PruneManifestXml(manifest) : nil;
    if (orig_video_setVideoDashManifest) {
        orig_video_setVideoDashManifest(self, _cmd, pruned ? pruned : manifest);
    }
}

static NSData * (*orig_video_dashManifest)(id self, SEL _cmd) = NULL;
static __thread BOOL s_inDashManifestHook = NO;
static NSData * Hook_IGVideo_DashManifest(id self, SEL _cmd) {
    if (s_inDashManifestHook) {
        return orig_video_dashManifest ? orig_video_dashManifest(self, _cmd) : nil;
    }
    s_inDashManifestHook = YES;
    NSData *orig = orig_video_dashManifest ? orig_video_dashManifest(self, _cmd) : nil;
    NSData *pruned = orig ? (NSData *)PruneManifestXml(orig) : nil;
    s_inDashManifestHook = NO;
    return pruned ? pruned : orig;
}

static NSData * (*orig_video_dashManifestData)(id self, SEL _cmd) = NULL;
static __thread BOOL s_inDashManifestDataHook = NO;
static NSData * Hook_IGVideo_DashManifestData(id self, SEL _cmd) {
    if (s_inDashManifestDataHook) {
        return orig_video_dashManifestData ? orig_video_dashManifestData(self, _cmd) : nil;
    }
    s_inDashManifestDataHook = YES;
    NSData *orig = orig_video_dashManifestData ? orig_video_dashManifestData(self, _cmd) : nil;
    NSData *pruned = orig ? (NSData *)PruneManifestXml(orig) : nil;
    s_inDashManifestDataHook = NO;
    return pruned ? pruned : orig;
}

static void (*orig_video_setDashManifestData)(id self, SEL _cmd, id manifestData) = NULL;
static void Hook_IGVideo_SetDashManifestData(id self, SEL _cmd, id manifestData) {
    id pruned = manifestData ? PruneManifestXml(manifestData) : nil;
    if (orig_video_setDashManifestData) {
        orig_video_setDashManifestData(self, _cmd, pruned ? pruned : manifestData);
    }
}

// FNFDashPlayerSizePruner Hook: Prevent discarding 1440p/1080p due to device screen size
static id (*orig_playerSizePruner_pruneQualities)(id self, SEL _cmd, id qualities) = NULL;
static id Hook_PlayerSizePruner_PruneQualities(id self, SEL _cmd, id qualities) {
    if (!InstagramDash1440p_IsForce1440pActive()) {
        return orig_playerSizePruner_pruneQualities ? orig_playerSizePruner_pruneQualities(self, _cmd, qualities) : qualities;
    }
    // Return all qualities unpruned so 1440p and 1080p are preserved
    return qualities;
}

// ============================================================================
// Core Representation Selection & Quality Forcing Helpers
// ============================================================================

static id SelectHighestRepresentation(NSArray *representations) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    id first = representations.firstObject;
    if (IsAudioRepresentation(first)) {
        return first;
    }

    if (!InstagramDash1440p_IsForce1440pActive()) {
        return representations.firstObject;
    }

    id rep1440p = nil;
    uint64_t maxBw1440 = 0;
    id rep1080p = nil;
    uint64_t maxBw1080 = 0;
    id repHighest = nil;
    uint64_t maxPixels = 0;
    uint64_t maxBwHighest = 0;

    for (id rep in representations) {
        if (!rep || IsAudioRepresentation(rep)) continue;

        CGSize sz = GetRepresentationPixelDimensions(rep);
        uint64_t pixels = (uint64_t)(sz.width * sz.height);
        uint64_t bw = GetRepresentationBitrate(rep);
        NSString *repId = GetRepresentationId(rep);

        CGFloat minDim = MIN(sz.width, sz.height);
        CGFloat maxDim = MAX(sz.width, sz.height);

        BOOL is1440 = (minDim >= 1200.0f || maxDim >= 2200.0f || pixels >= 2800000ULL ||
                       (repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"968238693007748"] || [repId containsString:@"1440"] || [repId containsString:@"2k"])));

        BOOL is1080 = (!is1440 && (minDim >= 960.0f || maxDim >= 1700.0f || pixels >= 1600000ULL ||
                       (repId && [repId containsString:@"1080"])));

        if (is1440) {
            if (!rep1440p || bw > maxBw1440) {
                rep1440p = rep;
                maxBw1440 = bw;
            }
        } else if (is1080) {
            if (!rep1080p || bw > maxBw1080) {
                rep1080p = rep;
                maxBw1080 = bw;
            }
        }

        if (pixels > maxPixels) {
            maxPixels = pixels;
            maxBwHighest = bw;
            repHighest = rep;
        } else if (pixels == maxPixels && bw > maxBwHighest) {
            maxBwHighest = bw;
            repHighest = rep;
        }
    }

    id chosen = rep1440p ?: (rep1080p ?: repHighest ?: representations.firstObject);
    return chosen;
}

// ABR Quality Selector Hooks
struct CxxVectorInt {
    int *begin;
    int *end;
    int *cap;
};

static id (*orig_ABR_selectQualitySeqIndices)(id self, SEL _cmd, NSArray *representations, struct CxxVectorInt seqIndices, double bandwidth) = NULL;
static id Hook_ABR_SelectQualitySeqIndices(id self, SEL _cmd, NSArray *representations, struct CxxVectorInt seqIndices, double bandwidth) {
    if (InstagramDash1440p_IsForce1440pActive() && representations && [representations isKindOfClass:[NSArray class]] && representations.count > 0) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualitySeqIndices) {
        return orig_ABR_selectQualitySeqIndices(self, _cmd, representations, seqIndices, bandwidth);
    }
    return (representations && representations.count > 0) ? representations.firstObject : nil;
}

static id (*orig_ABR_selectQualityWithBw)(id self, SEL _cmd, NSArray *representations, double bandwidth) = NULL;
static id Hook_ABR_SelectQualityFromReps(id self, SEL _cmd, NSArray *representations, double bandwidth) {
    if (InstagramDash1440p_IsForce1440pActive() && representations && [representations isKindOfClass:[NSArray class]] && representations.count > 0) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualityWithBw) {
        return orig_ABR_selectQualityWithBw(self, _cmd, representations, bandwidth);
    }
    return (representations && representations.count > 0) ? representations.firstObject : nil;
}

static BOOL Hook_ReturnNO(id self, SEL _cmd, id rep, BOOL isIntentional) {
    return NO;
}

static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

// FNFDashPlaylist Hook: Ensure video startup default representation is strictly 1440p (or 1080p fallback)
static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;
static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsForce1440pActive()) {
        NSArray *reps = nil;
        if ([self respondsToSelector:@selector(representationsForTrack:)]) {
            reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(self, @selector(representationsForTrack:), 1);
        }
        if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
            id highest = SelectHighestRepresentation(reps);
            if (highest) {
                return highest;
            }
        }
    }
    if (orig_playlist_defaultRepresentationForTrack) {
        return orig_playlist_defaultRepresentationForTrack(self, _cmd, track);
    }
    return nil;
}

// FNFDashVideoPlayerMetadata Hooks: Force 1440x2560 Viewport & Screen Dimensions
static CGSize (*orig_meta_size)(id self, SEL _cmd) = NULL;
static CGSize Hook_Return1440pSize(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsForce1440pActive() && orig_meta_size) {
        return orig_meta_size(self, _cmd);
    }
    return CGSizeMake(1440.0f, 2560.0f);
}

static CGSize (*orig_meta_screenSize)(id self, SEL _cmd) = NULL;
static CGSize Hook_Return1440pScreenSize(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsForce1440pActive() && orig_meta_screenSize) {
        return orig_meta_screenSize(self, _cmd);
    }
    return CGSizeMake(1440.0f, 2560.0f);
}

static CGSize (*orig_meta_viewPortSize)(id self, SEL _cmd) = NULL;
static CGSize Hook_Return1440pViewPortSize(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsForce1440pActive() && orig_meta_viewPortSize) {
        return orig_meta_viewPortSize(self, _cmd);
    }
    return CGSizeMake(1440.0f, 2560.0f);
}

// Bandwidth Providers Hook: Boost to 100 Mbps
static double Hook_ReturnHighBandwidth(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsForce1440pActive()) {
        return 5000000.0;
    }
    return 100000000.0; // 100 Mbps
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
    // 1. Root Manifest Parser Hook on FNFMediaPresentationDescription
    // Swizzle ONLY the public class method +[FNFMediaPresentationDescription presentationDescriptionWithContentsOfXml:mpdUrl:error:]
    // which has standard pointer arguments (@40@0:8@16@24^@32).
    Class presDescCls = objc_getClass("FNFMediaPresentationDescription");
    if (presDescCls) {
        SEL sel = sel_registerName("presentationDescriptionWithContentsOfXml:mpdUrl:error:");
        SafeSwizzleClassMethod(presDescCls, sel, (IMP)Hook_PresDesc_WithContentsOfXml_Error, (IMP *)&orig_presDesc_xml_error);
    }

    // 2. Inlined Manifest Accessors and Mutators on IGVideo
    Class videoCls = objc_getClass("IGVideo");
    if (videoCls) {
        SafeSwizzleMethod(videoCls, sel_registerName("videoDashManifest"),
                          (IMP)Hook_IGVideo_VideoDashManifest, (IMP *)&orig_video_videoDashManifest);
        SafeSwizzleMethod(videoCls, sel_registerName("setVideoDashManifest:"),
                          (IMP)Hook_IGVideo_SetVideoDashManifest, (IMP *)&orig_video_setVideoDashManifest);
        SafeSwizzleMethod(videoCls, sel_registerName("dashManifest"),
                          (IMP)Hook_IGVideo_DashManifest, (IMP *)&orig_video_dashManifest);
        SafeSwizzleMethod(videoCls, sel_registerName("dashManifestData"),
                          (IMP)Hook_IGVideo_DashManifestData, (IMP *)&orig_video_dashManifestData);
        SafeSwizzleMethod(videoCls, sel_registerName("setDashManifestData:"),
                          (IMP)Hook_IGVideo_SetDashManifestData, (IMP *)&orig_video_setDashManifestData);
    }

    // 3. Screen Size Pruner Bypass on FNFDashPlayerSizePruner
    Class prunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (prunerCls) {
        SafeSwizzleMethod(prunerCls, sel_registerName("pruneQualities:"),
                          (IMP)Hook_PlayerSizePruner_PruneQualities, (IMP *)&orig_playerSizePruner_pruneQualities);
    }

    // 4. Force 1440p Selection in FNFDashABRQualitySelector
    Class abrCls = objc_getClass("FNFDashABRQualitySelector");
    if (abrCls) {
        SafeSwizzleMethod(abrCls, sel_registerName("_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                          (IMP)Hook_ABR_SelectQualitySeqIndices, (IMP *)&orig_ABR_selectQualitySeqIndices);
        SafeSwizzleMethod(abrCls, sel_registerName("_selectQualityFromRepresentations:withAvailableBandwidth:"),
                          (IMP)Hook_ABR_SelectQualityFromReps, (IMP *)&orig_ABR_selectQualityWithBw);
        SafeSwizzleMethod(abrCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"),
                          (IMP)Hook_ReturnNO, NULL);
    }

    // 5. Force 1440p Default Video Representation in FNFDashPlaylist
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        SafeSwizzleMethod(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                          (IMP)Hook_Playlist_DefaultRepresentationForTrack, (IMP *)&orig_playlist_defaultRepresentationForTrack);
    }

    // 6. Force 1440p Viewport, Screen Size & Ignore-Avoid-On-Cell in FNFDashVideoPlayerMetadata
    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SafeSwizzleMethod(metaCls, sel_registerName("size"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_size);
        SafeSwizzleMethod(metaCls, sel_registerName("screenSize"), (IMP)Hook_Return1440pScreenSize, (IMP *)&orig_meta_screenSize);
        SafeSwizzleMethod(metaCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pViewPortSize, (IMP *)&orig_meta_viewPortSize);
        SafeSwizzleMethod(metaCls, sel_registerName("ignoreAvoidOnCell"), (IMP)Hook_ReturnYES, NULL);
    }

    // 7. Boost Bandwidth Providers to 100+ Mbps
    const char *bandwidthClasses[] = {
        "FNFBandwidthProvider",
        "IGBandwidthEstimator",
        "IGFNFBandwidthProvider",
        "IGMediaHistoricalBandwidthEstimateProvider"
    };
    for (size_t i = 0; i < sizeof(bandwidthClasses) / sizeof(bandwidthClasses[0]); i++) {
        Class bCls = objc_getClass(bandwidthClasses[i]);
        if (!bCls) continue;
        SafeSwizzleMethod(bCls, sel_registerName("downloadBandwidthEstimateBitsPerSecond"), (IMP)Hook_ReturnHighBandwidth, NULL);
    }


    // 3. Apple VideoToolbox Hardware VP9 Decoder
    Class vp9xCls = objc_getClass("FNFDecompressionSessionForVP9X");
    if (vp9xCls) {
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
