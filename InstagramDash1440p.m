// InstagramDash1440p.m
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unlocks full 1440p (2560x1440) DASH video playback on Wi-Fi and Cellular data by:
// 1. Overriding FNF player size pruning (reporting 1440x2560 viewport and screen dimensions).
// 2. Disabling representation pruning in FNFDashPlayerSizePruner & FNFDashPlayerQualityPruner.
// 3. Ensuring 1440p / maximum bitrate representation selection in FNFDashABRPlayerSizeQualitySelector.
// 4. Bypassing Avoid-On-Cell (AOC) representation restrictions.
// 5. Supporting runtime toggle via 20px modal for standard vs 1440p behavior.
// 6. Accurately extracting server representation info ("fdash-%id") and discriminating true 1440p vs 1080p.

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

// Discriminates true 1440p vs 1080p and formats full server filename as "fdash-%id"
static void UpdateRepresentationInfo(id rep) {
    if (!rep) return;

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

    // Check actual video resolution
    BOOL is1440p = NO;
    CGSize sz = CGSizeZero;
    if ([rep respondsToSelector:@selector(videoSize)]) {
        sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(videoSize));
    }
    if (CGSizeEqualToSize(sz, CGSizeZero) && [rep respondsToSelector:@selector(size)]) {
        sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(size));
    }

    NSString *label = nil;
    if ([rep respondsToSelector:@selector(qualityLabel)]) {
        label = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(qualityLabel));
    }

    if (sz.width >= 1440.0f || sz.height >= 2560.0f) {
        is1440p = YES;
    } else if (label && ([label containsString:@"1440"] || [label localizedCaseInsensitiveContainsString:@"2k"])) {
        is1440p = YES;
    } else if (repId && ([repId containsString:@"1440"] || [repId localizedCaseInsensitiveContainsString:@"2k"])) {
        is1440p = YES;
    }

    // Strictly discriminate: only 1440p if actually 1440p, otherwise 1080p
    NSString *quality = is1440p ? @"1440p" : @"1080p";

    // Format full filename as "fdash-%id"
    NSString *fdashName = nil;
    if (repId && repId.length > 0) {
        if ([repId hasPrefix:@"fdash-"]) {
            fdashName = repId;
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
// Core Representation Selection Logic (1440p Priority & Max Bitrate Filter)
// Uses strict ARM64 ABI typed message sends to prevent memory corruption/crashes
// ============================================================================

static id SelectHighestRepresentation(NSArray *representations) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    id bestRep = nil;
    uint64_t maxMetric = 0;

    for (id rep in representations) {
        if (!rep) continue;

        // 1. Explicit 1440p / 2K quality label match (qualityLabel returns NSString *)
        if ([rep respondsToSelector:@selector(qualityLabel)]) {
            NSString *label = ((NSString *(*)(id, SEL))objc_msgSend)(rep, @selector(qualityLabel));
            if ([label isKindOfClass:[NSString class]]) {
                if ([label containsString:@"1440"] || [label localizedCaseInsensitiveContainsString:@"2k"]) {
                    DashLog("Found explicit 1440p representation by label: %@", label);
                    UpdateRepresentationInfo(rep);
                    return rep;
                }
            }
        }

        // 2. Direct pixel dimension check (videoSize returns CGSize struct in d0/d1)
        if ([rep respondsToSelector:@selector(videoSize)]) {
            CGSize sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(videoSize));
            if (sz.width >= 1440.0f || sz.height >= 2560.0f) {
                DashLog("Found 1440p representation by videoSize: %.0fx%.0f", sz.width, sz.height);
                UpdateRepresentationInfo(rep);
                return rep;
            }
        }

        // 3. Size selector check (size returns CGSize struct in d0/d1)
        if ([rep respondsToSelector:@selector(size)]) {
            CGSize sz = ((CGSize (*)(id, SEL))objc_msgSend)(rep, @selector(size));
            if (sz.width >= 1440.0f || sz.height >= 2560.0f) {
                DashLog("Found 1440p representation by size: %.0fx%.0f", sz.width, sz.height);
                UpdateRepresentationInfo(rep);
                return rep;
            }
        }

        // 4. Bitrate / Bandwidth comparison (bandwidth returns uint32_t primitive)
        uint64_t bw = 0;
        if ([rep respondsToSelector:@selector(bandwidth)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bandwidth));
        } else if ([rep respondsToSelector:@selector(bitrate)]) {
            bw = (uint64_t)((uint32_t (*)(id, SEL))objc_msgSend)(rep, @selector(bitrate));
        }

        if (bw > maxMetric) {
            maxMetric = bw;
            bestRep = rep;
        }
    }

    id finalRep = bestRep ?: representations.firstObject;
    if (finalRep) {
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

// Selects highest/1440p representation within FNFDashABRPlayerSizeQualitySelector
static id (*orig_ABRPlayerSize_selectQualityFromReps)(id self, SEL _cmd, NSArray *reps, double bw) = NULL;

static id Hook_ABRPlayerSize_SelectQualityFromReps(id self, SEL _cmd, NSArray *representations, double bandwidth) {
    if (InstagramDash1440p_IsEnabled()) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            UpdateRepresentationInfo(chosen);
            return chosen;
        }
    }
    if (orig_ABRPlayerSize_selectQualityFromReps) {
        id stdRep = orig_ABRPlayerSize_selectQualityFromReps(self, _cmd, representations, bandwidth);
        UpdateRepresentationInfo(stdRep);
        return stdRep;
    }
    return representations.firstObject;
}

// Selects highest/1440p representation within FNFDashABRQualitySelector
static id (*orig_ABR_selectQualityFromReps)(id self, SEL _cmd, NSArray *reps, void *seqIndices, double bw) = NULL;

static id Hook_ABR_SelectQualityFromReps(id self, SEL _cmd, NSArray *representations, void *seqIndices, double bandwidth) {
    if (InstagramDash1440p_IsEnabled()) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            UpdateRepresentationInfo(chosen);
            return chosen;
        }
    }
    if (orig_ABR_selectQualityFromReps) {
        id stdRep = orig_ABR_selectQualityFromReps(self, _cmd, representations, seqIndices, bandwidth);
        UpdateRepresentationInfo(stdRep);
        return stdRep;
    }
    return representations.firstObject;
}

// Sets 1440p default video representation on FNFDashPlaylist (track 1 = Video)
static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) { // 1 = Video Track
        if ([self respondsToSelector:@selector(representationsForTrack:)]) {
            NSArray *reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(self, @selector(representationsForTrack:), track);
            if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
                id highest = SelectHighestRepresentation(reps);
                if (highest) {
                    UpdateRepresentationInfo(highest);
                    return highest;
                }
            }
        }
    }
    if (orig_playlist_defaultRepresentationForTrack) {
        id stdRep = orig_playlist_defaultRepresentationForTrack(self, _cmd, track);
        if (track == 1 && stdRep) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return nil;
}

// Captures representation updates from IGFNFSelectedQualityProvider
static void (*orig_selectedQualityProvider_setVideoSelectedQualityRep)(id self, SEL _cmd, id rep) = NULL;

static void Hook_SelectedQualityProvider_SetVideoSelectedQualityRep(id self, SEL _cmd, id rep) {
    if (rep) {
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

    // 2. Select Highest 1440p Representation in FNFDashABRPlayerSizeQualitySelector
    Class abrPlayerSizeCls = objc_getClass("FNFDashABRPlayerSizeQualitySelector");
    if (abrPlayerSizeCls) {
        SwizzleBoth(abrPlayerSizeCls, sel_registerName("_selectQualityFromRepresentations:withAvailableBandwidth:"),
                    (IMP)Hook_ABRPlayerSize_SelectQualityFromReps,
                    (IMP *)&orig_ABRPlayerSize_selectQualityFromReps, "@@:@d");
        SwizzleBoth(abrPlayerSizeCls, sel_registerName("_shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
        SwizzleBoth(abrPlayerSizeCls, sel_registerName("shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ShouldSkipRepAOC, NULL, "B@:@B");
    }

    // 3. Select Highest 1440p Representation in FNFDashABRQualitySelector
    Class abrCls = objc_getClass("FNFDashABRQualitySelector");
    if (abrCls) {
        SwizzleBoth(abrCls, sel_registerName("_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                    (IMP)Hook_ABR_SelectQualityFromReps,
                    (IMP *)&orig_ABR_selectQualityFromReps, "@@:@^vd");
        SwizzleBoth(abrCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"), (IMP)Hook_ReturnNO, NULL, "B@:@B");
    }

    // 4. Force Wi-Fi State & Lock 1440p Default Video Representation in FNFDashPlaylist
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        SwizzleBoth(playlistCls, sel_registerName("isOnWifi"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(playlistCls, sel_registerName("isOnCell"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                    (IMP)Hook_Playlist_DefaultRepresentationForTrack,
                    (IMP *)&orig_playlist_defaultRepresentationForTrack, "@@:q");
    }

    // 5. Intercept Active Quality Selection in IGFNFSelectedQualityProvider
    Class sqpCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (sqpCls) {
        SwizzleBoth(sqpCls, sel_registerName("setVideoSelectedQualityRepresentation:"),
                    (IMP)Hook_SelectedQualityProvider_SetVideoSelectedQualityRep,
                    (IMP *)&orig_selectedQualityProvider_setVideoSelectedQualityRep, "v@:@");
    }

    // 6. Force 1440p Viewport, Screen Size & Ignore-Avoid-On-Cell in FNFDashVideoPlayerMetadata
    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SwizzleBoth(metaCls, sel_registerName("size"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_size, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("screenSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_screenSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pSize, (IMP *)&orig_meta_viewPortSize, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("ignoreAvoidOnCell"), (IMP)Hook_ReturnYES, NULL, "B@:");
    }

    // 7. Disable Data Saver Mode and Bandwidth Resolution Capping
    const char *dashConfigClasses[] = {
        "FNFDashPlaylistManager",
        "FNFDashManifestMetadata",
        "FNFDashConfig"
    };

    for (size_t i = 0; i < sizeof(dashConfigClasses) / sizeof(dashConfigClasses[0]); i++) {
        Class cls = objc_getClass(dashConfigClasses[i]);
        if (!cls) continue;
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
