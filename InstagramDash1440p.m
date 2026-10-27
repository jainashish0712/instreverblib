// InstagramDash1440p.m
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unconditionally forces full 1440p (2560x1440) DASH video playback on Wi-Fi and Cellular data by:
// 1. Locking 1440p representation selection across all FNFDash quality selectors via -selectQuality.
// 2. Intercepting FNFDashSelectionMetadata (selectedRepresentation and initializers) to guarantee 1440p delivery to fetchers.
// 3. Overriding FNFDashChunkManager _selectFetchRepresentation to return the highest 1440p video representation.
// 4. Overriding FNFDashPlaylist defaultRepresentationForTrack:, setDefaultRepresentation:track:, and updateDefaultRepresentationForTrack:.
// 5. Overriding FNF player size pruning (reporting 1440x2560 viewport and screen dimensions).
// 6. Bypassing representation pruning in FNFDashPlayerSizePruner & FNFDashPlayerQualityPruner.
// 7. Boosting bandwidth estimation providers to 100+ Mbps so ABR logic never caps representation resolution.
// 8. Enabling embedded FFmpeg VP9 decoding sessions and hardware decoding passes.
// 9. Strictly isolating audio representations from video representations so audio tracks never overwrite video modal state.
// 10. Supporting runtime toggle via 20px modal for standard vs 1440p behavior.
// 11. Accurately extracting server representation info ("fdash-%id") and discriminating true 1440p vs 1080p.

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

static __weak id g_lastHighestVideoRep = nil;
static const char *kPlaylistHighestVideoRepKey = "kPlaylistHighestVideoRepKey";

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
            w = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(width));
        }
        if ([rep respondsToSelector:@selector(videoHeight)]) {
            h = (CGFloat)((NSInteger (*)(id, SEL))objc_msgSend)(rep, @selector(videoHeight));
        } else if ([rep respondsToSelector:@selector(height)]) {
            h = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(height));
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
                    w = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(tmeta, @selector(width));
                }
                if ([tmeta respondsToSelector:@selector(height)]) {
                    h = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(tmeta, @selector(height));
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
                    w = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(meta, @selector(width));
                }
                if ([meta respondsToSelector:@selector(height)]) {
                    h = (CGFloat)((uint32_t (*)(id, SEL))objc_msgSend)(meta, @selector(height));
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
    uint64_t pixels = (uint64_t)(sz.width * sz.height);
    BOOL is1440p = (pixels >= 1440ULL * 2560ULL || sz.width >= 1440.0f || sz.height >= 2560.0f);

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
// ============================================================================

static id SelectHighestRepresentation(NSArray *representations) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    // Check if these are audio representations
    id first = representations.firstObject;
    if (IsAudioRepresentation(first)) {
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

        // Direct 1440p match (width >= 1440 or height >= 2560 or pixel count >= 3.6M or known ID match)
        if (pixels >= 1440ULL * 2560ULL || sz.width >= 1440.0f || sz.height >= 2560.0f || (repId && [repId containsString:@"1539525017490074"])) {
            DashLog("Locked onto 1440p representation: %@ (%.0fx%.0f, bandwidth: %llu)", repId, sz.width, sz.height, bw);
            UpdateRepresentationInfo(rep);
            g_lastHighestVideoRep = rep;
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
        g_lastHighestVideoRep = bestRep;
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
        g_lastHighestVideoRep = finalRep;
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

// Helper to safely extract FNFDashPlaylist from an object
static id ExtractPlaylistFromObject(id obj) {
    if (!obj) return nil;
    if ([obj respondsToSelector:@selector(representationsForTrack:)]) {
        return obj;
    }
    if ([obj respondsToSelector:@selector(playlist)]) {
        id pl = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(playlist));
        if (pl && [pl respondsToSelector:@selector(representationsForTrack:)]) {
            return pl;
        }
    }
    @try {
        id pl = [obj valueForKey:@"_playlist"];
        if (pl && [pl respondsToSelector:@selector(representationsForTrack:)]) {
            return pl;
        }
    } @catch (id ex) {}
    return nil;
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

static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

static BOOL Hook_ReturnNO(id self, SEL _cmd) {
    return NO;
}

static id Hook_ReturnNil(id self, SEL _cmd) {
    return nil;
}

static int Hook_Return4(id self, SEL _cmd) {
    return 4;
}

static int Hook_Return1(id self, SEL _cmd) {
    return 1;
}

static double Hook_ReturnHighBandwidth(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsEnabled()) {
        return 1000000.0;
    }
    return 100000000.0; // 100 Mbps
}

static double Hook_ReturnHighKBPS(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsEnabled()) {
        return 1000.0;
    }
    return 100000.0; // 100 Mbps in KBPS
}

static NSInteger Hook_ReturnReachabilityWiFi(id self, SEL _cmd) {
    return 2; // ReachableViaWiFi
}

static NSString *Hook_ReturnUserSelectedHigh(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsEnabled()) {
        return @"UserSelectedQualityAuto";
    }
    return @"UserSelectedQualityHigh";
}

// NO-OP representation disabling in FNFDashPlaylist
static void Hook_NoOpRepresentationDisable(id self, SEL _cmd) {
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

// ----------------------------------------------------------------------------
// FNFDashPlaylist Hooks
// ----------------------------------------------------------------------------

static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id playlist = ExtractPlaylistFromObject(self);
        if (playlist) {
            id cachedHighest = objc_getAssociatedObject(playlist, kPlaylistHighestVideoRepKey);
            if (cachedHighest) {
                UpdateRepresentationInfo(cachedHighest);
                return cachedHighest;
            }
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
                id highest = SelectHighestRepresentation(reps);
                if (highest) {
                    objc_setAssociatedObject(playlist, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    UpdateRepresentationInfo(highest);
                    return highest;
                }
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

static void (*orig_playlist_setDefaultRepresentation)(id self, SEL _cmd, id rep, NSInteger track) = NULL;

static void Hook_Playlist_SetDefaultRepresentation(id self, SEL _cmd, id rep, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id playlist = ExtractPlaylistFromObject(self);
        if (playlist) {
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
                id highest = SelectHighestRepresentation(reps);
                if (highest) {
                    rep = highest;
                    objc_setAssociatedObject(playlist, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
    }
    if (orig_playlist_setDefaultRepresentation) {
        orig_playlist_setDefaultRepresentation(self, _cmd, rep, track);
    }
}

static void (*orig_playlist_updateDefaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static void Hook_Playlist_UpdateDefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id playlist = ExtractPlaylistFromObject(self);
        if (playlist) {
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
                id highest = SelectHighestRepresentation(reps);
                if (highest) {
                    objc_setAssociatedObject(playlist, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if ([playlist respondsToSelector:@selector(setDefaultRepresentation:track:)]) {
                        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(playlist, @selector(setDefaultRepresentation:track:), highest, 1);
                        return;
                    }
                }
            }
        }
    }
    if (orig_playlist_updateDefaultRepresentationForTrack) {
        orig_playlist_updateDefaultRepresentationForTrack(self, _cmd, track);
    }
}

static NSArray * (*orig_playlist_representationsForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static NSArray * Hook_Playlist_RepresentationsForTrack(id self, SEL _cmd, NSInteger track) {
    NSArray *reps = orig_playlist_representationsForTrack ? orig_playlist_representationsForTrack(self, _cmd, track) : nil;
    if (track == 1 && InstagramDash1440p_IsEnabled() && reps && reps.count > 0) {
        id highest = SelectHighestRepresentation(reps);
        if (highest) {
            objc_setAssociatedObject(self, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UpdateRepresentationInfo(highest);
        }
    }
    return reps;
}

// ----------------------------------------------------------------------------
// Quality Selector -selectQuality Hooks (Universal for all quality selectors)
// ----------------------------------------------------------------------------

static id (*orig_qualitySelector_selectQuality)(id self, SEL _cmd) = NULL;

static id Hook_QualitySelector_SelectQuality(id self, SEL _cmd) {
    id selection = orig_qualitySelector_selectQuality ? orig_qualitySelector_selectQuality(self, _cmd) : nil;
    if (!InstagramDash1440p_IsEnabled() || !selection) {
        return selection;
    }

    // Check if selection is for video (track 1)
    NSInteger track = 1;
    if ([selection respondsToSelector:@selector(trackType)]) {
        track = ((NSInteger (*)(id, SEL))objc_msgSend)(selection, @selector(trackType));
    }
    if (track != 1) {
        return selection;
    }

    id playlist = ExtractPlaylistFromObject(self);
    id highest = nil;
    if (playlist) {
        highest = objc_getAssociatedObject(playlist, kPlaylistHighestVideoRepKey);
        if (!highest && [playlist respondsToSelector:@selector(representationsForTrack:)]) {
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            highest = SelectHighestRepresentation(reps);
            if (highest) {
                objc_setAssociatedObject(playlist, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (!highest) {
        highest = g_lastHighestVideoRep;
    }

    if (highest) {
        // Substitute selectedRepresentation on selection
        @try {
            [selection setValue:highest forKey:@"_selectedRepresentation"];
        } @catch (id ex) {
            // Direct ivar backup: offset 8 in FNFDashSelectionMetadata
            *(id *)((uintptr_t)selection + 8) = highest;
        }
        UpdateRepresentationInfo(highest);
    }

    return selection;
}

// ----------------------------------------------------------------------------
// FNFDashSelectionMetadata Hooks
// ----------------------------------------------------------------------------

static id (*orig_selMeta_selectedRepresentation)(id self, SEL _cmd) = NULL;

static id Hook_SelMeta_SelectedRepresentation(id self, SEL _cmd) {
    id rep = orig_selMeta_selectedRepresentation ? orig_selMeta_selectedRepresentation(self, _cmd) : nil;
    if (!InstagramDash1440p_IsEnabled() || !rep || IsAudioRepresentation(rep)) {
        return rep;
    }
    NSInteger track = 1;
    if ([self respondsToSelector:@selector(trackType)]) {
        track = ((NSInteger (*)(id, SEL))objc_msgSend)(self, @selector(trackType));
    }
    if (track == 1 && g_lastHighestVideoRep) {
        CGSize sz = GetRepresentationPixelDimensions(rep);
        if (sz.width < 1440.0f && sz.height < 2560.0f) {
            UpdateRepresentationInfo(g_lastHighestVideoRep);
            return g_lastHighestVideoRep;
        }
    }
    if (rep && !IsAudioRepresentation(rep)) {
        UpdateRepresentationInfo(rep);
    }
    return rep;
}

static id (*orig_selMeta_initWithSelectedRepQualityTrack)(id self, SEL _cmd, id rep, id qMeta, NSInteger track) = NULL;

static id Hook_SelMeta_InitWithSelectedRepQualityTrack(id self, SEL _cmd, id rep, id qMeta, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id playlist = ExtractPlaylistFromObject(qMeta);
        if (playlist) {
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            id highest = SelectHighestRepresentation(reps);
            if (highest) {
                rep = highest;
            }
        } else if (g_lastHighestVideoRep) {
            rep = g_lastHighestVideoRep;
        }
    }
    if (orig_selMeta_initWithSelectedRepQualityTrack) {
        return orig_selMeta_initWithSelectedRepQualityTrack(self, _cmd, rep, qMeta, track);
    }
    return self;
}

static id (*orig_selMeta_initWithSelectedRepTrack)(id self, SEL _cmd, id rep, NSInteger track) = NULL;

static id Hook_SelMeta_InitWithSelectedRepTrack(id self, SEL _cmd, id rep, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled() && g_lastHighestVideoRep) {
        rep = g_lastHighestVideoRep;
    }
    if (orig_selMeta_initWithSelectedRepTrack) {
        return orig_selMeta_initWithSelectedRepTrack(self, _cmd, rep, track);
    }
    return self;
}

// ----------------------------------------------------------------------------
// FNFDashChunkManager Hook
// ----------------------------------------------------------------------------

static id (*orig_chunkMgr_selectFetchRep)(id self, SEL _cmd) = NULL;

static id Hook_ChunkMgr_SelectFetchRepresentation(id self, SEL _cmd) {
    id result = orig_chunkMgr_selectFetchRep ? orig_chunkMgr_selectFetchRep(self, _cmd) : nil;
    if (!InstagramDash1440p_IsEnabled() || !result) {
        return result;
    }

    NSInteger track = 1;
    @try {
        id trVal = [self valueForKey:@"_track"];
        if (trVal) track = [trVal integerValue];
    } @catch (id ex) {}

    if (track == 1) {
        id playlist = ExtractPlaylistFromObject(self);
        if (playlist) {
            id cachedHighest = objc_getAssociatedObject(playlist, kPlaylistHighestVideoRepKey);
            if (cachedHighest) {
                UpdateRepresentationInfo(cachedHighest);
                return cachedHighest;
            }
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 1);
            id highest = SelectHighestRepresentation(reps);
            if (highest) {
                objc_setAssociatedObject(playlist, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UpdateRepresentationInfo(highest);
                return highest;
            }
        }
        if (g_lastHighestVideoRep) {
            UpdateRepresentationInfo(g_lastHighestVideoRep);
            return g_lastHighestVideoRep;
        }
    }

    if (result && !IsAudioRepresentation(result)) {
        UpdateRepresentationInfo(result);
    }
    return result;
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

        SwizzleBoth(qCls, sel_registerName("selectQuality"),
                    (IMP)Hook_QualitySelector_SelectQuality, (IMP *)&orig_qualitySelector_selectQuality, "@@:");
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
        SwizzleBoth(playlistCls, sel_registerName("setDefaultRepresentation:track:"),
                    (IMP)Hook_Playlist_SetDefaultRepresentation,
                    (IMP *)&orig_playlist_setDefaultRepresentation, "v@:@q");
        SwizzleBoth(playlistCls, sel_registerName("updateDefaultRepresentationForTrack:"),
                    (IMP)Hook_Playlist_UpdateDefaultRepresentationForTrack,
                    (IMP *)&orig_playlist_updateDefaultRepresentationForTrack, "v@:q");
        SwizzleBoth(playlistCls, sel_registerName("representationsForTrack:"),
                    (IMP)Hook_Playlist_RepresentationsForTrack,
                    (IMP *)&orig_playlist_representationsForTrack, "@@:q");

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

    // 4. Hook FNFDashSelectionMetadata (delivers representation to chunk fetcher)
    Class selMetaCls = objc_getClass("FNFDashSelectionMetadata");
    if (selMetaCls) {
        SwizzleBoth(selMetaCls, sel_registerName("selectedRepresentation"),
                    (IMP)Hook_SelMeta_SelectedRepresentation,
                    (IMP *)&orig_selMeta_selectedRepresentation, "@@:");
        SwizzleBoth(selMetaCls, sel_registerName("initWithSelectedRepresentation:qualityMetadata:trackType:"),
                    (IMP)Hook_SelMeta_InitWithSelectedRepQualityTrack,
                    (IMP *)&orig_selMeta_initWithSelectedRepQualityTrack, "@@:@@q");
        SwizzleBoth(selMetaCls, sel_registerName("initWithSelectedRepresentation:trackType:"),
                    (IMP)Hook_SelMeta_InitWithSelectedRepTrack,
                    (IMP *)&orig_selMeta_initWithSelectedRepTrack, "@@:@q");
    }

    // 5. Hook FNFDashChunkManager _selectFetchRepresentation
    Class chunkMgrCls = objc_getClass("FNFDashChunkManager");
    if (chunkMgrCls) {
        SwizzleBoth(chunkMgrCls, sel_registerName("_selectFetchRepresentation"),
                    (IMP)Hook_ChunkMgr_SelectFetchRepresentation,
                    (IMP *)&orig_chunkMgr_selectFetchRep, "@@:");
    }

    // 6. Intercept Active Quality Selection in IGFNFSelectedQualityProvider
    Class sqpCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (sqpCls) {
        SwizzleBoth(sqpCls, sel_registerName("setVideoSelectedQualityRepresentation:"),
                    (IMP)Hook_SelectedQualityProvider_SetVideoSelectedQualityRep,
                    (IMP *)&orig_selectedQualityProvider_setVideoSelectedQualityRep, "v@:@");
    }

    // 7. Force 1440p Viewport, Screen Size & Ignore-Avoid-On-Cell in FNFDashVideoPlayerMetadata
    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SwizzleBoth(metaCls, sel_registerName("size"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_size, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("screenSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_screenSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_viewPortSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("ignoreAvoidOnCell"), (IMP)Hook_ReturnYES, NULL, "B@:");
    }

    // 8. Boost Bandwidth Providers to 100+ Mbps so ABR never caps quality
    const char *bandwidthClasses[] = {
        "FNFBandwidthProvider",
        "IGBandwidthEstimator",
        "IGFNFBandwidthProvider",
        "IGMediaHistoricalBandwidthEstimateProvider"
    };

    for (size_t i = 0; i < sizeof(bandwidthClasses) / sizeof(bandwidthClasses[0]); i++) {
        Class bCls = objc_getClass(bandwidthClasses[i]);
        if (!bCls) continue;
        SwizzleBoth(bCls, sel_registerName("downloadBandwidthEstimateBitsPerSecond"), (IMP)Hook_ReturnHighBandwidth, NULL, "d@:");
        SwizzleBoth(bCls, sel_registerName("downloadBandwidthEstimate"), (IMP)Hook_ReturnHighBandwidth, NULL, "d@:");
        SwizzleBoth(bCls, sel_registerName("estimatedBandwidthKBPS"), (IMP)Hook_ReturnHighKBPS, NULL, "d@:");
        SwizzleBoth(bCls, sel_registerName("bandwidthEstimate"), (IMP)Hook_ReturnHighBandwidth, NULL, "d@:");
        SwizzleBoth(bCls, sel_registerName("currentReachabilityState"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    }

    // 9. Player & Video Item initial config
    Class playerCls = objc_getClass("FNFPlayer");
    if (playerCls) {
        SwizzleBoth(playerCls, sel_registerName("userSelectedQuality"), (IMP)Hook_ReturnUserSelectedHigh, NULL, "@@:");
    }

    Class itemCls = objc_getClass("FNFVideoPlaybackItem");
    if (itemCls) {
        SwizzleBoth(itemCls, sel_registerName("initialRepresentationID"), (IMP)Hook_ReturnNil, NULL, "@@:");
    }

    // 10. Enable Embedded FFmpeg VP9 & AV1 Decoding and Quality Configurations
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
        SwizzleBoth(cls, sel_registerName("checkForAV1DecompressionSessionCreationFailure"), (IMP)Hook_ReturnNO, NULL, "B@:");
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
