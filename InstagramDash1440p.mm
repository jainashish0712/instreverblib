// InstagramDash1440p.mm
// Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram
// Forces 1440p DASH video playback with strict 1080p fallback for active Reels & feed prefetchers

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <vector>
#import <string>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import "InstagramDash1440p.h"

NSString * const kInstagramDash1440pStateDidChangeNotification = @"kInstagramDash1440pStateDidChangeNotification";

static BOOL g_dash1440pEnabled = YES;
static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1080p";
static NSString *g_currentRepresentationId = @"ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

// ============================================================================
// Sandboxed Multi-Threaded File Logging (Documents/Instagram1440p.log)
// ============================================================================

static char g_docLogPath[1024] = {0};
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

static void ResolveLogPath(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject ?: @"/tmp";
        snprintf(g_docLogPath, sizeof(g_docLogPath), "%s/Instagram1440p.log", [docDir UTF8String]);
    });
}

static void DashLog(NSString *format, ...) {
    if (!format) return;
    ResolveLogPath();

    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[InstagramDash1440p] %@", msg);

    time_t rawtime;
    struct tm timeinfo;
    char timeBuf[32];
    time(&rawtime);
    localtime_r(&rawtime, &timeinfo);
    strftime(timeBuf, sizeof(timeBuf), "%Y-%m-%d %H:%M:%S", &timeinfo);

    NSString *line = [NSString stringWithFormat:@"[%s] [InstagramDash1440p] %@\n", timeBuf, msg];
    const char *utf8 = [line UTF8String];
    size_t len = strlen(utf8);

    pthread_mutex_lock(&g_logMutex);
    if (g_docLogPath[0] != '\0') {
        int fd = open(g_docLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, utf8, len);
            close(fd);
        }
    }
    pthread_mutex_unlock(&g_logMutex);
}

// ============================================================================
// Public Control & Telemetry Interfaces
// ============================================================================

BOOL InstagramDash1440p_IsEnabled(void) {
    pthread_mutex_lock(&g_stateMutex);
    BOOL enabled = g_dash1440pEnabled;
    pthread_mutex_unlock(&g_stateMutex);
    return enabled;
}

void InstagramDash1440p_SetEnabled(BOOL enabled) {
    pthread_mutex_lock(&g_stateMutex);
    g_dash1440pEnabled = enabled;
    pthread_mutex_unlock(&g_stateMutex);

    DashLog(@"1440p DASH Engine Toggled: %@", enabled ? @"ENABLED" : @"DISABLED");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

BOOL InstagramDash1440p_ToggleEnabled(void) {
    pthread_mutex_lock(&g_stateMutex);
    g_dash1440pEnabled = !g_dash1440pEnabled;
    BOOL newState = g_dash1440pEnabled;
    pthread_mutex_unlock(&g_stateMutex);

    DashLog(@"1440p DASH Engine Toggled: %@", newState ? @"ENABLED" : @"DISABLED");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
    return newState;
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

NSString *InstagramDash1440p_GetCurrentRepresentationId(void) {
    pthread_mutex_lock(&g_stateMutex);
    NSString *repId = [g_currentRepresentationId copy];
    pthread_mutex_unlock(&g_stateMutex);
    return repId;
}

NSString *InstagramDash1440p_GetLogFilePath(void) {
    ResolveLogPath();
    return [NSString stringWithUTF8String:g_docLogPath];
}

// ============================================================================
// Representation Introspection Helpers
// ============================================================================

static BOOL IsAudioRepresentation(id rep) {
    if (!rep) return NO;
    if ([rep respondsToSelector:@selector(isAudio)]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(rep, @selector(isAudio))) return YES;
    }
    if ([rep respondsToSelector:@selector(track)]) {
        if (((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(track)) == 2) return YES;
    }
    if ([rep respondsToSelector:@selector(representationId)]) {
        NSString *repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
        if (repId && [repId hasSuffix:@"a"]) return YES;
    }
    return NO;
}

static CGSize GetRepresentationPixelDimensions(id rep) {
    if (!rep) return CGSizeZero;
    CGSize sz = CGSizeZero;
    if ([rep respondsToSelector:@selector(videoSize)]) {
        sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(videoSize));
    }
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        if ([rep respondsToSelector:@selector(size)]) {
            sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(size));
        }
    }
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        CGFloat w = 0.0f, h = 0.0f;
        if ([rep respondsToSelector:@selector(videoWidth)]) {
            w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(videoWidth));
        } else if ([rep respondsToSelector:@selector(width)]) {
            w = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(width));
        }
        if ([rep respondsToSelector:@selector(videoHeight)]) {
            h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(videoHeight));
        } else if ([rep respondsToSelector:@selector(height)]) {
            h = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(height));
        }
        if (w > 0.0f && h > 0.0f) {
            sz = CGSizeMake(w, h);
        }
    }
    return sz;
}

static uint64_t GetRepresentationBitrate(id rep) {
    if (!rep) return 0;
    if ([rep respondsToSelector:@selector(bandwidth)]) {
        return (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bandwidth));
    }
    if ([rep respondsToSelector:@selector(bitrate)]) {
        return (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bitrate));
    }
    return 0;
}

static NSString *GetRepresentationId(id rep) {
    if (!rep) return nil;
    if ([rep respondsToSelector:@selector(representationId)]) {
        NSString *repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
        if (repId && repId.length > 0) return repId;
    }
    if ([rep respondsToSelector:@selector(qualityLabel)]) {
        NSString *label = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(qualityLabel));
        if (label && label.length > 0) return label;
    }
    return nil;
}

// ============================================================================
// State & Telemetry Updates
// ============================================================================

static void UpdateActiveRepresentation(id rep, BOOL isPrefetch) {
    if (!rep || IsAudioRepresentation(rep)) return;

    CGSize sz = GetRepresentationPixelDimensions(rep);
    uint64_t pixels = (uint64_t)(sz.width * sz.height);
    NSString *repId = GetRepresentationId(rep) ?: @"unknown";
    uint64_t bw = GetRepresentationBitrate(rep);

    BOOL is1440 = (pixels >= 1440ULL * 2560ULL || sz.width >= 1440.0f || sz.height >= 2560.0f ||
                   [repId containsString:@"1539525017490074"] || [repId containsString:@"1440"]);
    BOOL is1080 = (!is1440 && (pixels >= 1080ULL * 1920ULL || sz.width >= 1080.0f || sz.height >= 1920.0f ||
                   [repId containsString:@"1080"]));

    NSString *quality = is1440 ? @"1440p" : (is1080 ? @"1080p" : [NSString stringWithFormat:@"%.0fp", MIN(sz.width, sz.height)]);

    if (isPrefetch) {
        DashLog(@"[Prefetch Engine] Queued offscreen chunk: %@ (%@, %.0fx%.0f, %llu bps)",
                quality, repId, sz.width, sz.height, bw);
        return;
    }

    BOOL changed = NO;
    pthread_mutex_lock(&g_stateMutex);
    if (g_isActual1440p != is1440 ||
        ![g_currentQuality isEqualToString:quality] ||
        ![g_currentRepresentationId isEqualToString:repId]) {
        g_isActual1440p = is1440;
        g_currentQuality = [quality copy];
        g_currentRepresentationId = [repId copy];
        changed = YES;
    }
    pthread_mutex_unlock(&g_stateMutex);

    if (changed) {
        DashLog(@"[Active Playback] Representation locked: %@ (%@, %.0fx%.0f, %llu bps)",
                quality, repId, sz.width, sz.height, bw);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
        });
    }
}

// ============================================================================
// Core Resolution-First Target Representation Selector
// ============================================================================

static id SelectTargetRepresentation(NSArray *representations, BOOL isPrefetch) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    id rep1440p = nil;
    uint64_t maxBw1440p = 0;

    id rep1080p = nil;
    uint64_t maxBw1080p = 0;

    id repHighest = nil;
    uint64_t maxPixelsGeneral = 0;
    uint64_t maxBwGeneral = 0;

    for (id rep in representations) {
        if (!rep || IsAudioRepresentation(rep)) continue;

        CGSize sz = GetRepresentationPixelDimensions(rep);
        uint64_t pixels = (uint64_t)(sz.width * sz.height);
        uint64_t bw = GetRepresentationBitrate(rep);
        NSString *repId = GetRepresentationId(rep);

        BOOL is1440 = (pixels >= 1440ULL * 2560ULL || sz.width >= 1440.0f || sz.height >= 2560.0f ||
                       (repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"1440"])));

        BOOL is1080 = (!is1440 && (pixels >= 1080ULL * 1920ULL || sz.width >= 1080.0f || sz.height >= 1920.0f ||
                       (repId && [repId containsString:@"1080"])));

        // 1. Evaluate 1440p pool (strictly prioritize resolution over bitrate inversion)
        if (is1440) {
            if (!rep1440p || bw > maxBw1440p) {
                rep1440p = rep;
                maxBw1440p = bw;
            }
        }

        // 2. Evaluate 1080p fallback floor
        if (is1080) {
            if (!rep1080p || bw > maxBw1080p) {
                rep1080p = rep;
                maxBw1080p = bw;
            }
        }

        // 3. Evaluate general max pool for non-HD edge cases
        if (pixels > maxPixelsGeneral) {
            maxPixelsGeneral = pixels;
            maxBwGeneral = bw;
            repHighest = rep;
        } else if (pixels == maxPixelsGeneral && bw > maxBwGeneral) {
            maxBwGeneral = bw;
            repHighest = rep;
        }
    }

    // Strict hierarchy: 1440p -> 1080p -> Max available
    id chosen = rep1440p ?: rep1080p ?: repHighest ?: representations.firstObject;
    if (chosen && !IsAudioRepresentation(chosen)) {
        UpdateActiveRepresentation(chosen, isPrefetch);
    }
    return chosen;
}

// ============================================================================
// Objective-C Swizzle Helpers
// ============================================================================

static void SafeSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return;

    if (origImp && !*origImp) {
        *origImp = orig;
    }

    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }
}

// ============================================================================
// Hook Implementations
// ============================================================================

// 1. FNFDashPlayerSizePruner Hook: Bypass representation pruning without touching viewports
static NSArray * (*orig_sizePruner_pruneQualities)(id self, SEL _cmd, NSArray *qualities) = NULL;

static NSArray * Hook_PruneQualitiesNoOp(id self, SEL _cmd, NSArray *qualities) {
    if (!InstagramDash1440p_IsEnabled() && orig_sizePruner_pruneQualities) {
        return orig_sizePruner_pruneQualities(self, _cmd, qualities);
    }
    return qualities;
}

// 2. FNFDashPlaylist Hook: Force 1440p/1080p Default Representation for Background Prefetchers
static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        NSArray *reps = nil;
        if ([self respondsToSelector:@selector(representationsForTrack:)]) {
            reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(self, @selector(representationsForTrack:), 1);
        }
        if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
            id chosen = SelectTargetRepresentation(reps, YES); // YES = prefetch
            if (chosen) {
                return chosen;
            }
        }
    }
    if (orig_playlist_defaultRepresentationForTrack) {
        return orig_playlist_defaultRepresentationForTrack(self, _cmd, track);
    }
    return nil;
}

// 3. FNFDashABRQualitySelector Hook: ABI-Safe std::vector<int> Quality Selection
static id (*orig_ABR_selectQualitySeqIndices)(id self, SEL _cmd, NSArray *representations, std::vector<int> seqIndices, double bandwidth) = NULL;

static id Hook_ABR_SelectQualitySeqIndices(id self, SEL _cmd, NSArray *representations, std::vector<int> seqIndices, double bandwidth) {
    if (InstagramDash1440p_IsEnabled() && representations && [representations isKindOfClass:[NSArray class]] && representations.count > 0) {
        id chosen = SelectTargetRepresentation(representations, NO);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualitySeqIndices) {
        return orig_ABR_selectQualitySeqIndices(self, _cmd, representations, seqIndices, bandwidth);
    }
    return representations.firstObject;
}

// 4. VideoToolbox Hardware/Hybrid VP9 Decoding Activation
static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

static BOOL Hook_ReturnNO(id self, SEL _cmd, id rep, BOOL isIntentional) {
    return NO;
}

// 5. Active Telemetry Observer Hook
static void (*orig_qualityProvider_videoQualitySelected)(id self, SEL _cmd, id rep, id meta, NSInteger track) = NULL;

static void Hook_QualityProvider_VideoQualitySelected(id self, SEL _cmd, id rep, id meta, NSInteger track) {
    if (track == 1 && rep && !IsAudioRepresentation(rep)) {
        BOOL isIntentional = YES;
        if (meta && [meta respondsToSelector:@selector(isIntentional)]) {
            isIntentional = ((BOOL (*)(id, SEL))objc_msgSend)(meta, @selector(isIntentional));
        }
        if (isIntentional) {
            UpdateActiveRepresentation(rep, NO);
        }
    }
    if (orig_qualityProvider_videoQualitySelected) {
        orig_qualityProvider_videoQualitySelected(self, _cmd, rep, meta, track);
    }
}

// ============================================================================
// Swizzle Registration & Initialization
// ============================================================================

static void SwizzleDashClasses(void) {
    DashLog(@"Registering 1440p VP9 DASH hooks...");

    // 1. Bypass Player Size Pruning in FNFDashPlayerSizePruner
    Class sizePrunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (sizePrunerCls) {
        SafeSwizzleMethod(sizePrunerCls, sel_registerName("pruneQualities:"),
                          (IMP)Hook_PruneQualitiesNoOp, (IMP *)&orig_sizePruner_pruneQualities);
        DashLog(@"[Swizzle] FNFDashPlayerSizePruner pruneQualities: swizzled");
    }

    // 2. Force 1440p/1080p in FNFDashPlaylist defaultRepresentationForTrack: (Prefetch & Instant Startup)
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        SafeSwizzleMethod(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                          (IMP)Hook_Playlist_DefaultRepresentationForTrack, (IMP *)&orig_playlist_defaultRepresentationForTrack);
        DashLog(@"[Swizzle] FNFDashPlaylist defaultRepresentationForTrack: swizzled");
    }

    // 3. Force 1440p/1080p in FNFDashABRQualitySelector
    Class abrCls = objc_getClass("FNFDashABRQualitySelector");
    if (abrCls) {
        SafeSwizzleMethod(abrCls, sel_registerName("_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                          (IMP)Hook_ABR_SelectQualitySeqIndices, (IMP *)&orig_ABR_selectQualitySeqIndices);
        SafeSwizzleMethod(abrCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"),
                          (IMP)Hook_ReturnNO, NULL);
        DashLog(@"[Swizzle] FNFDashABRQualitySelector swizzled successfully");
    }

    // 4. Activate VideoToolbox VP9 Hardware/Hybrid Decoding
    const char *vp9Classes[] = {
        "FNFPlayerConfig",
        "FNFDecompressionConfig"
    };
    for (size_t i = 0; i < sizeof(vp9Classes) / sizeof(vp9Classes[0]); i++) {
        Class vCls = objc_getClass(vp9Classes[i]);
        if (!vCls) continue;
        SafeSwizzleMethod(vCls, sel_registerName("enableVTForVP9"), (IMP)Hook_ReturnYES, NULL);
        DashLog(@"[Swizzle] %s enableVTForVP9 swizzled", vp9Classes[i]);
    }

    // 5. Active Telemetry Observer
    Class qualityProviderCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (qualityProviderCls) {
        SafeSwizzleMethod(qualityProviderCls, sel_registerName("videoQualitySelected:playerMetadata:trackType:"),
                          (IMP)Hook_QualityProvider_VideoQualitySelected, (IMP *)&orig_qualityProvider_videoQualitySelected);
        DashLog(@"[Swizzle] IGFNFSelectedQualityProvider swizzled");
    }

    DashLog(@"1440p VP9 DASH hook registration complete");
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
        ResolveLogPath();

        DashLog(@"==================================================================");
        DashLog(@"Initializing Ultra-HD 1440p VP9 DASH Video Engine for Instagram");
        DashLog(@"Target Log: %s", g_docLogPath);
        DashLog(@"Active Reels & Feed Prefetchers: 1440p Priority, 1080p Fallback Floor");
        DashLog(@"Apple VideoToolbox VP9 Hardware/Hybrid Decoder Enabled");
        DashLog(@"==================================================================");

        ApplyAllDash1440pSwizzles();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                           object:nil
                                                            queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification * _Nonnull note) {
            DashLog(@"UIApplicationDidFinishLaunchingNotification received, refreshing swizzles");
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
