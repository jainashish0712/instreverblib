// InstagramDash1440p.m
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unlocks full 1440p (2560x1440) DASH video playback on Wi-Fi and Cellular data by:
// 1. Overriding FNF player size pruning (reporting 1440x2560 viewport and screen dimensions).
// 2. Disabling representation pruning in FNFDashPlayerSizePruner & FNFDashPlayerQualityPruner.
// 3. Ensuring 1440p / maximum bitrate representation selection across all FNFDash quality selectors.
// 4. Enabling embedded FFmpeg VP9 decoding sessions (enableFFVP9Decoding, ffvp9EnableFastFlag, ffvp9ThreadCount).
// 5. Strictly isolating audio representations from video representations so audio tracks never overwrite video modal state.
// 6. Bypassing Avoid-On-Cell (AOC) representation restrictions and playlist representation disabling.
// 7. Supporting runtime toggle via 20px modal for standard vs 1440p behavior.
// 8. Accurately extracting server representation info ("fdash-%id") and discriminating true 1440p vs 1080p.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#import "InstagramDash1440p.h"

#define DashLog(fmt, ...) NSLog(@"[InstagramDash1440p] " fmt, ##__VA_ARGS__)

NSString * const kInstagramDash1440pStateDidChangeNotification = @"kInstagramDash1440pStateDidChangeNotification";

static BOOL g_dash1440pEnabled = YES;
static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1080p";
static NSString *g_currentFdashFilename = @"fdash-ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

BOOL InstagramDash1440p_IsEnabled(void) {
    return g_dash1440pEnabled;
}

void InstagramDash1440p_SetEnabled(BOOL enabled) {
    pthread_mutex_lock(&g_stateMutex);
    g_dash1440pEnabled = enabled;
    pthread_mutex_unlock(&g_stateMutex);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

BOOL InstagramDash1440p_ToggleEnabled(void) {
    pthread_mutex_lock(&g_stateMutex);
    g_dash1440pEnabled = !g_dash1440pEnabled;
    BOOL newState = g_dash1440pEnabled;
    pthread_mutex_unlock(&g_stateMutex);
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
    NSString *copy = [g_currentQuality copy];
    pthread_mutex_unlock(&g_stateMutex);
    return copy;
}

NSString *InstagramDash1440p_GetCurrentFilename(void) {
    pthread_mutex_lock(&g_stateMutex);
    NSString *copy = [g_currentFdashFilename copy];
    pthread_mutex_unlock(&g_stateMutex);
    return copy;
}

void InstagramDash1440p_SetCurrentFilename(NSString *filename) {
    if (!filename || filename.length == 0) return;
    pthread_mutex_lock(&g_stateMutex);
    if (![g_currentFdashFilename isEqualToString:filename]) {
        g_currentFdashFilename = [filename copy];
        pthread_mutex_unlock(&g_stateMutex);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
        });
        return;
    }
    pthread_mutex_unlock(&g_stateMutex);
}

// Determines if an FNF representation is an audio track
static BOOL IsAudioRepresentation(id rep) {
    if (!rep) return NO;
    if ([rep respondsToSelector:@selector(isAudio)]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(rep, @selector(isAudio))) {
            return YES;
        }
    }
    if ([rep respondsToSelector:@selector(track)]) {
        NSInteger tr = ((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(track));
        if (tr == 2) {
            return YES;
        }
    }
    if ([rep respondsToSelector:@selector(representationId)]) {
        NSString *repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
        if (repId && [repId hasSuffix:@"a"]) {
            return YES;
        }
    }
    return NO;
}

// Extracts pixel dimensions (width x height) from any FNF representation or metadata object
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
        CGFloat w = 0, h = 0;
        if ([rep respondsToSelector:@selector(videoWidth)]) {
            w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(videoWidth));
        } else if ([rep respondsToSelector:@selector(width)]) {
            w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(width));
        }
        if ([rep respondsToSelector:@selector(videoHeight)]) {
            h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(videoHeight));
        } else if ([rep respondsToSelector:@selector(height)]) {
            h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(height));
        }
        if (w > 0 && h > 0) {
            sz = CGSizeMake(w, h);
        }
    }
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        if ([rep respondsToSelector:@selector(trackMetadata)]) {
            id tmeta = ((id (*)(id, SEL))objc_msgSend)(rep, @selector(trackMetadata));
            if (tmeta) {
                CGFloat w = 0, h = 0;
                if ([tmeta respondsToSelector:@selector(width)]) {
                    w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(tmeta, @selector(width));
                }
                if ([tmeta respondsToSelector:@selector(height)]) {
                    h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(tmeta, @selector(height));
                }
                if (w > 0 && h > 0) {
                    sz = CGSizeMake(w, h);
                }
            }
        }
    }
    if (sz.width <= 0.0f || sz.height <= 0.0f) {
        if ([rep respondsToSelector:@selector(metadata)]) {
            id meta = ((id (*)(id, SEL))objc_msgSend)(rep, @selector(metadata));
            if (meta) {
                CGFloat w = 0, h = 0;
                if ([meta respondsToSelector:@selector(width)]) {
                    w = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(meta, @selector(width));
                }
                if ([meta respondsToSelector:@selector(height)]) {
                    h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(meta, @selector(height));
                }
                if (w > 0 && h > 0) {
                    sz = CGSizeMake(w, h);
                }
            }
        }
    }
    return sz;
}

// Discriminates true 1440p vs 1080p and formats full server filename as "fdash-%id"
static void UpdateRepresentationInfo(id rep) {
    if (!rep) return;
    if (IsAudioRepresentation(rep)) {
        // Audio representations MUST NEVER overwrite video representation state!
        return;
    }

    NSString *repId = nil;
    if ([rep respondsToSelector:@selector(representationId)]) {
        repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
    }
    if ((!repId || repId.length == 0) && [rep respondsToSelector:@selector(qualityLabel)]) {
        repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(qualityLabel));
    }
    if ((!repId || repId.length == 0) && [rep respondsToSelector:@selector(description)]) {
        repId = [rep description];
    }

    // Check actual video pixel resolution
    CGSize sz = GetRepresentationPixelDimensions(rep);
    BOOL is1440p = (sz.width >= 1440.0f || sz.height >= 2560.0f);

    if (!is1440p && repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"1440"])) {
        is1440p = YES;
    }

    // Fallback only if pixel dimensions were unavailable from all selectors
    if (!is1440p && sz.width <= 0.0f && sz.height <= 0.0f) {
        NSString *label = nil;
        if ([rep respondsToSelector:@selector(qualityLabel)]) {
            label = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(qualityLabel));
        }
        if (label && ([label containsString:@"1440"] || [label localizedCaseInsensitiveContainsString:@"2k"])) {
            is1440p = YES;
        }
    }

    // Strictly discriminate: only 1440p if actually 1440p, otherwise 1080p
    NSString *quality = is1440p ? @"1440p" : @"1080p";

    // Format full filename as "fdash-%id"
    NSString *fdashName = nil;
    if (repId && repId.length > 0) {
        if ([repId hasPrefix:@"fdash-"]) {
            fdashName = repId;
        } else if ([repId hasPrefix:@"dash-"]) {
            fdashName = [NSString stringWithFormat:@"f%@", repId];
        } else {
            fdashName = [NSString stringWithFormat:@"fdash-%@", repId];
        }
    } else {
        fdashName = [NSString stringWithFormat:@"fdash-%@", quality];
    }

    pthread_mutex_lock(&g_stateMutex);
    g_isActual1440p = is1440p;
    g_currentQuality = [quality copy];
    g_currentFdashFilename = [fdashName copy];
    pthread_mutex_unlock(&g_stateMutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
    });
}

void InstagramDash1440p_SetCurrentRepresentation(id rep) {
    UpdateRepresentationInfo(rep);
}

// ============================================================================
// Core Representation Selection Logic (1440p Priority & Max Pixel Resolution Filter)
// Uses strict ARM64 ABI typed message sends to prevent memory corruption/crashes
//
// Key Technical Insight:
// Meta's server DASH manifests frequently mark 1080p streams with qualityLabel="1440p",
// and variable bitrate encoding (VBR) can cause 1080p to have a HIGHER average bitrate
// than true 1440p (e.g. 5804 kbps on 1080p vs 5642 kbps on 1440p).
// Therefore, representations MUST be ranked by TRUE PIXEL RESOLUTION (width * height),
// completely ignoring misleading qualityLabel strings and deceptive bitrate spikes.
// ============================================================================

static id SelectHighestRepresentation(NSArray *representations) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    // Check if these are audio representations
    id first = representations.firstObject;
    if (IsAudioRepresentation(first)) {
        // Audio representations: select highest audio bitrate without touching video state
        id bestAudio = first;
        uint64_t maxBw = 0;
        for (id rep in representations) {
            uint64_t bw = 0;
            if ([rep respondsToSelector:@selector(bandwidth)]) {
                bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bandwidth));
            } else if ([rep respondsToSelector:@selector(bitrate)]) {
                bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bitrate));
            }
            if (bw > maxBw) {
                maxBw = bw;
                bestAudio = rep;
            }
        }
        return bestAudio;
    }

    id bestRep = nil;
    uint64_t maxPixelCount = 0;
    uint64_t maxBandwidth = 0;

    // Pass 1: Rank by true pixel resolution (1440x2560 = 3,686,400 pixels vs 1080x1920 = 2,073,600 pixels)
    for (id rep in representations) {
        if (!rep || IsAudioRepresentation(rep)) continue;

        CGSize sz = GetRepresentationPixelDimensions(rep);
        uint64_t pixels = (uint64_t)(sz.width * sz.height);

        uint64_t bw = 0;
        if ([rep respondsToSelector:@selector(bandwidth)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bandwidth));
        } else if ([rep respondsToSelector:@selector(bitrate)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bitrate));
        }

        NSString *repId = nil;
        if ([rep respondsToSelector:@selector(representationId)]) {
            repId = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(representationId));
        }

        // Direct 1440p match (width >= 1440 or height >= 2560 or ID match)
        if (sz.width >= 1440.0f || sz.height >= 2560.0f || (repId && [repId containsString:@"1539525017490074"])) {
            DashLog("Locked onto 1440p representation: %@ (%.0fx%.0f, bandwidth: %llu)", repId, sz.width, sz.height, bw);
            UpdateRepresentationInfo(rep);
            return rep;
        }

        if (pixels > maxPixelCount) {
            maxPixelCount = pixels;
            maxBandwidth = bw;
            bestRep = rep;
        } else if (pixels == maxPixelCount && bw > maxBandwidth) {
            maxBandwidth = bw;
            bestRep = rep;
        }
    }

    if (bestRep) {
        UpdateRepresentationInfo(bestRep);
        return bestRep;
    }

    // Pass 2: Fallback to highest bandwidth video representation
    for (id rep in representations) {
        if (!rep || IsAudioRepresentation(rep)) continue;
        uint64_t bw = 0;
        if ([rep respondsToSelector:@selector(bandwidth)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bandwidth));
        } else if ([rep respondsToSelector:@selector(bitrate)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bitrate));
        }

        if (bw > maxBandwidth) {
            maxBandwidth = bw;
            bestRep = rep;
        }
    }

    id finalRep = bestRep ?: representations.firstObject;
    if (finalRep && !IsAudioRepresentation(finalRep)) {
        UpdateRepresentationInfo(finalRep);
    }
    return finalRep;
}

// ============================================================================
// Objective-C Swizzle Helpers
// ============================================================================

static void SafeSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origImp, BOOL isClassMethod, const char *typeEncoding) {
    if (!cls || !sel || !newImp) return;
    Class targetCls = isClassMethod ? object_getClass((id)cls) : cls;
    if (!targetCls) return;

    Method method = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (method) {
        const char *types = method_getTypeEncoding(method);
        if (!types) types = typeEncoding;
        IMP orig = method_getImplementation(method);
        if (origImp && !*origImp) {
            *origImp = orig;
        }
        if (!class_addMethod(targetCls, sel, newImp, types)) {
            method_setImplementation(method, newImp);
        }
    } else {
        class_addMethod(targetCls, sel, newImp, typeEncoding ?: "v@:");
    }
}

static void SwizzleBoth(Class cls, SEL sel, IMP newImp, IMP *origImp, const char *typeEncoding) {
    if (!cls) return;
    SafeSwizzleMethod(cls, sel, newImp, origImp, NO, typeEncoding);
    SafeSwizzleMethod(cls, sel, newImp, NULL, YES, typeEncoding);
}

// ============================================================================
// Hook Implementations
// ============================================================================

// Bypasses representation pruning so 1440p representations are never discarded
static id (*orig_sizePruner_pruneQualities)(id self, SEL _cmd, id qualities) = NULL;

static id Hook_PruneQualitiesNoOp(id self, SEL _cmd, id qualities) {
    if (!InstagramDash1440p_IsEnabled() && orig_sizePruner_pruneQualities) {
        return orig_sizePruner_pruneQualities(self, _cmd, qualities);
    }
    // Return all qualities unpruned
    return qualities;
}

// Forces playerSize, screenSize, and viewPortSize to report 1440x2560 dimensions
static CGSize (*orig_meta_size)(id self, SEL _cmd) = NULL;
static CGSize (*orig_meta_screenSize)(id self, SEL _cmd) = NULL;
static CGSize (*orig_meta_viewPortSize)(id self, SEL _cmd) = NULL;

static CGSize Hook_Return1440pSize(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsEnabled()) {
        if (orig_meta_viewPortSize) return orig_meta_viewPortSize(self, _cmd);
        if (orig_meta_size) return orig_meta_size(self, _cmd);
    }
    return CGSizeMake(1440.0f, 2560.0f);
}

// Prevents skipping high quality representations on cellular or Wi-Fi (Avoid-On-Cell)
static BOOL Hook_ShouldSkipRepAOC(id self, SEL _cmd, id rep, BOOL isOnWifi) {
    if (!InstagramDash1440p_IsEnabled()) {
        return YES;
    }
    return NO;
}

// General YES stub
static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

// General NO stub
static BOOL Hook_ReturnNO(id self, SEL _cmd) {
    return NO;
}

// Thread count for VP9 software decoder (4 cores for smooth 1440p 60fps playback)
static int Hook_Return4(id self, SEL _cmd) {
    return 4;
}

// Thread type for VP9 software decoder (1 = frame threading)
static int Hook_Return1(id self, SEL _cmd) {
    return 1;
}

// NO-OP representation disabling in FNFDashPlaylist
static void Hook_NoOpRepresentationDisable(id self, SEL _cmd) {
    // Prevent FNF from disabling or dropping high resolution representations
}

// Selects highest/1440p representation within FNFDashABRQualitySelector (sequenceIndices variant)
static id (*orig_ABR_selectQualityFromReps)(id self, SEL _cmd, NSArray *reps, void *seqIndices, double bw) = NULL;

static id Hook_ABR_SelectQualityFromReps(id self, SEL _cmd, NSArray *representations, void *seqIndices, double bandwidth) {
    if (InstagramDash1440p_IsEnabled()) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualityFromReps) {
        id stdRep = orig_ABR_selectQualityFromReps(self, _cmd, representations, seqIndices, bandwidth);
        if (stdRep && !IsAudioRepresentation(stdRep)) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return representations.firstObject;
}

// Selects highest/1440p representation within FNFDashABRQualitySelector (fetchSizesInBytes variant)
static id (*orig_ABR_selectQualityFetchSizes)(id self, SEL _cmd, NSArray *reps, void *fetchSizes, void *seqIndexes) = NULL;

static id Hook_ABR_SelectQualityFetchSizes(id self, SEL _cmd, NSArray *representations, void *fetchSizes, void *seqIndexes) {
    if (InstagramDash1440p_IsEnabled()) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualityFetchSizes) {
        id stdRep = orig_ABR_selectQualityFetchSizes(self, _cmd, representations, fetchSizes, seqIndexes);
        if (stdRep && !IsAudioRepresentation(stdRep)) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return representations.firstObject;
}

// Selects highest/1440p representation within FNFDashABRQualitySelector (bandwidth variant)
static id (*orig_ABR_selectQualityBandwidth)(id self, SEL _cmd, NSArray *reps, double bw) = NULL;

static id Hook_ABR_SelectQualityBandwidth(id self, SEL _cmd, NSArray *representations, double bandwidth) {
    if (InstagramDash1440p_IsEnabled()) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualityBandwidth) {
        id stdRep = orig_ABR_selectQualityBandwidth(self, _cmd, representations, bandwidth);
        if (stdRep && !IsAudioRepresentation(stdRep)) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return representations.firstObject;
}

// Sets 1440p default video representation on FNFDashPlaylist (track 1 = Video)
static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) { // 1 = Video Track
        NSArray *reps = nil;
        if ([self respondsToSelector:@selector(representationsForTrack:)]) {
            reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(self, @selector(representationsForTrack:), track);
        } else if ([self respondsToSelector:@selector(_representationsForVideoTrack)]) {
            reps = ((NSArray *(*)(id, SEL))objc_msgSend)(self, @selector(_representationsForVideoTrack));
        } else if ([self respondsToSelector:@selector(_videoRepresentations)]) {
            reps = ((NSArray *(*)(id, SEL))objc_msgSend)(self, @selector(_videoRepresentations));
        }
        if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
            id highest = SelectHighestRepresentation(reps);
            if (highest) {
                UpdateRepresentationInfo(highest);
                return highest;
            }
        }
    }
    if (orig_playlist_defaultRepresentationForTrack) {
        id stdRep = orig_playlist_defaultRepresentationForTrack(self, _cmd, track);
        if (track == 1 && stdRep && !IsAudioRepresentation(stdRep)) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return nil;
}

// Captures representation updates from IGFNFSelectedQualityProvider
static void (*orig_selectedQualityProvider_setVideoSelectedQualityRep)(id self, SEL _cmd, id rep) = NULL;

static void Hook_SelectedQualityProvider_SetVideoSelectedQualityRep(id self, SEL _cmd, id rep) {
    if (rep && !IsAudioRepresentation(rep)) {
        UpdateRepresentationInfo(rep);
    }
    if (orig_selectedQualityProvider_setVideoSelectedQualityRep) {
        orig_selectedQualityProvider_setVideoSelectedQualityRep(self, _cmd, rep);
    }
}

// ============================================================================
// Class Hook Installation
// ============================================================================

static void SwizzleDashClasses(void) {
    // 1. Bypass Player Size Pruning in FNFDashPlayerSizePruner & FNFDashPlayerQualityPruner
    Class sizePrunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (sizePrunerCls) {
        SwizzleBoth(sizePrunerCls, sel_registerName("pruneQualities:"),
                    (IMP)Hook_PruneQualitiesNoOp, (IMP *)&orig_sizePruner_pruneQualities, "@@:@");
    }

    Class qualityPrunerCls = objc_getClass("FNFDashPlayerQualityPruner");
    if (qualityPrunerCls) {
        SwizzleBoth(qualityPrunerCls, sel_registerName("pruneQualities:"), (IMP)Hook_PruneQualitiesNoOp, NULL, "@@:@");
        SwizzleBoth(qualityPrunerCls, sel_registerName("_shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
        SwizzleBoth(qualityPrunerCls, sel_registerName("shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
    }

    // 2. Select Highest 1440p Representation across all quality selectors
    const char *qualitySelectorClasses[] = {
        "FNFDashABRPlayerSizeQualitySelector",
        "FNFDashABRQualitySelector",
        "FNFDashABRSizeBasedBweQualitySelector",
        "FNFDashCacheQualitySelector",
        "FNFDashMaxQualitySelector",
        "FNFDashMinQualitySelector",
        "FNFDashRandomQualitySelector",
        "FNFDashRoundRobinQualitySelector",
        "FNFDashUserSelectedQualitySelector",
        "FNFDashMultiRepUserSelectedQualitySelector",
        "FNFDashDefaultQualitySelector",
        "FNFDashPrefetchQualitySelector",
        "IGFNFDashQualityManager",
        "FNFStitchQualityEvaluator",
        "IGFNFStitchQualityManager",
        "IGFNFBusyHourQualitySelector"
    };

    for (size_t i = 0; i < sizeof(qualitySelectorClasses) / sizeof(qualitySelectorClasses[0]); i++) {
        Class qCls = objc_getClass(qualitySelectorClasses[i]);
        if (!qCls) continue;

        SwizzleBoth(qCls, sel_registerName("_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                    (IMP)Hook_ABR_SelectQualityFromReps, (IMP *)&orig_ABR_selectQualityFromReps, "@@:@^vd");
        SwizzleBoth(qCls, sel_registerName("selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                    (IMP)Hook_ABR_SelectQualityFromReps, NULL, "@@:@^vd");
        SwizzleBoth(qCls, sel_registerName("_selectQualityFromRepresentations:fetchSizesInBytes:sequenceIndexes:"),
                    (IMP)Hook_ABR_SelectQualityFetchSizes, (IMP *)&orig_ABR_selectQualityFetchSizes, "@@:@^v^v");
        SwizzleBoth(qCls, sel_registerName("selectQualityFromRepresentations:fetchSizesInBytes:sequenceIndexes:"),
                    (IMP)Hook_ABR_SelectQualityFetchSizes, NULL, "@@:@^v^v");
        SwizzleBoth(qCls, sel_registerName("_selectQualityFromRepresentations:withAvailableBandwidth:"),
                    (IMP)Hook_ABR_SelectQualityBandwidth, (IMP *)&orig_ABR_selectQualityBandwidth, "@@:@d");
        SwizzleBoth(qCls, sel_registerName("selectQualityFromRepresentations:withAvailableBandwidth:"),
                    (IMP)Hook_ABR_SelectQualityBandwidth, NULL, "@@:@d");
        SwizzleBoth(qCls, sel_registerName("_shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
        SwizzleBoth(qCls, sel_registerName("shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
        SwizzleBoth(qCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"), (IMP)Hook_ReturnNO, NULL, "B@:@B");
    }

    // 3. Force Wi-Fi State & Lock 1440p Default Video Representation in FNFDashPlaylist & Managers
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        SwizzleBoth(playlistCls, sel_registerName("isOnWifi"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(playlistCls, sel_registerName("isOnCell"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                    (IMP)Hook_Playlist_DefaultRepresentationForTrack,
                    (IMP *)&orig_playlist_defaultRepresentationForTrack, "@@:q");
        // Prevent disabling high-res representations
        SwizzleBoth(playlistCls, sel_registerName("_disableRepresentationsFromMpd:withComparison:disableMessage:disableCode:"),
                    (IMP)Hook_NoOpRepresentationDisable, NULL, "v@:@@@i");
        SwizzleBoth(playlistCls, sel_registerName("_disableRemovedRepresentations:"),
                    (IMP)Hook_NoOpRepresentationDisable, NULL, "v@:@");
        SwizzleBoth(playlistCls, sel_registerName("_disableLaneDroppedRepresentation:"),
                    (IMP)Hook_NoOpRepresentationDisable, NULL, "v@:@");
        SwizzleBoth(playlistCls, sel_registerName("_disableRepresentationsWithMisalignedPredictiveNumbers:"),
                    (IMP)Hook_NoOpRepresentationDisable, NULL, "v@:@");
        SwizzleBoth(playlistCls, sel_registerName("_disableRepresentationsWithMisalignedTimelines:"),
                    (IMP)Hook_NoOpRepresentationDisable, NULL, "v@:@");
    }

    Class playlistMgrCls = objc_getClass("FNFDashPlaylistManager");
    if (playlistMgrCls) {
        SwizzleBoth(playlistMgrCls, sel_registerName("defaultRepresentationForTrack:"),
                    (IMP)Hook_Playlist_DefaultRepresentationForTrack, NULL, "@@:q");
    }

    Class igQualityMgrCls = objc_getClass("IGFNFDashQualityManager");
    if (igQualityMgrCls) {
        SwizzleBoth(igQualityMgrCls, sel_registerName("defaultRepresentationForTrack:"),
                    (IMP)Hook_Playlist_DefaultRepresentationForTrack, NULL, "@@:q");
    }

    // 4. Intercept Active Quality Selection in IGFNFSelectedQualityProvider
    Class sqpCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (sqpCls) {
        SwizzleBoth(sqpCls, sel_registerName("setVideoSelectedQualityRepresentation:"),
                    (IMP)Hook_SelectedQualityProvider_SetVideoSelectedQualityRep,
                    (IMP *)&orig_selectedQualityProvider_setVideoSelectedQualityRep, "v@:@");
    }

    // 5. Force 1440p Viewport, Screen Size & Ignore-Avoid-On-Cell in FNFDashVideoPlayerMetadata
    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SwizzleBoth(metaCls, sel_registerName("size"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_size, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("screenSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_screenSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_viewPortSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("ignoreAvoidOnCell"), (IMP)Hook_ReturnYES, NULL, "B@:");
    }

    // 6. Enable Embedded FFmpeg VP9 Decoding and Quality Configurations
    const char *vp9ConfigClasses[] = {
        "FNFDecompressionConfig",
        "FNFPlayerConfig",
        "FNFPlayerDefaultConfig",
        "FNFDashConfig",
        "FNFDashConfigGen",
        "FNFDashDefaultConfigForVod",
        "FNFDashDefaultConfigForLive",
        "FNFDashManifestMetadata",
        "FNFDecompressionFFVP9",
        "FNFVP9Decompression",
        "FNFDashPlaylistManager",
        "FNFDashPlaylist"
    };

    for (size_t i = 0; i < sizeof(vp9ConfigClasses) / sizeof(vp9ConfigClasses[0]); i++) {
        Class cls = objc_getClass(vp9ConfigClasses[i]);
        if (!cls) continue;
        SwizzleBoth(cls, sel_registerName("enableFFVP9Decoding"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("enableFFVP9ZeroCopyDecoding"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("ffvp9EnableFastFlag"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("ffvp9ThreadCount"), (IMP)Hook_Return4, NULL, "i@:");
        SwizzleBoth(cls, sel_registerName("ffvp9ThreadType"), (IMP)Hook_Return1, NULL, "i@:");
        SwizzleBoth(cls, sel_registerName("enableVTForVP9"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("enableVP9VTDecodingDimensionCheck"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("checkForVP9DecompressionSessionCreationFailure"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("processDecompressionSessionCreationFailure"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("isUserDataSaverModeEnabled"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(cls, sel_registerName("bandwidthLimitedResolutionsDisabled"), (IMP)Hook_ReturnYES, NULL, "B@:");
    }
}

static void ApplyAllDash1440pSwizzles(void) {
    static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_mutex);

    SwizzleDashClasses();

    pthread_mutex_unlock(&s_mutex);
}

static void ImageLoadedCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    ApplyAllDash1440pSwizzles();
}

// ============================================================================
// Public Interface & Auto-Initialization
// ============================================================================

void InstagramDash1440p_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[InstagramDash1440p] ========================================================");
        NSLog(@"[InstagramDash1440p] Initializing Ultra-HD 1440p DASH Video Streaming Engine");
        NSLog(@"[InstagramDash1440p] Overriding FNF Player Size Pruner: Viewport set to 1440x2560");
        NSLog(@"[InstagramDash1440p] 1440p / Maximum Bitrate Representation Selector Active");
        NSLog(@"[InstagramDash1440p] Embedded FFmpeg VP9 Software Decoder Enabled (4 threads)");

        // 1. Initial Swizzle Pass
        ApplyAllDash1440pSwizzles();

        // 2. Monitor future loaded Mach-O images (e.g. FBSharedFramework)
        _dyld_register_func_for_add_image(ImageLoadedCallback);

        // 3. Re-evaluate once app finishes launching
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                           object:nil
                                                            queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification * _Nonnull note) {
            ApplyAllDash1440pSwizzles();
        }];

        // 4. Delayed check for late-instantiated ABR singletons
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApplyAllDash1440pSwizzles();
        });

        NSLog(@"[InstagramDash1440p] 1440p DASH Streaming Engine Active: Max Quality Locked");
        NSLog(@"[InstagramDash1440p] ========================================================");
    });
}

BOOL InstagramDash1440p_IsActive(void) {
    return YES;
}

__attribute__((constructor))
static void InstagramDash1440pAutoInit(void) {
    InstagramDash1440p_Init();
}
