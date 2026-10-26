// InstagramDash1440p.m
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unlocks full 1440p (2560x1440) DASH video playback on Wi-Fi by:
// 1. Overriding FNF player size pruning (reporting 1440x2560 viewport dimensions).
// 2. Disabling screen-width representation capping in FNFDashPlayerSizePruner.
// 3. Forcing selection of 1440p / maximum bitrate DASH video representations in FNFDashQualityManager.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#import "InstagramDash1440p.h"

#define DashLog(fmt, ...) NSLog(@"[InstagramDash1440p] " fmt, ##__VA_ARGS__)

// ============================================================================
// Core Representation Selection Logic (1440p Priority & Max Bitrate Filter)
// ============================================================================

static id SelectHighestRepresentation(NSArray *representations) {
    if (!representations || ![representations isKindOfClass:[NSArray class]] || representations.count == 0) {
        return nil;
    }

    id bestRep = nil;
    uint64_t maxMetric = 0;

    for (id rep in representations) {
        if (!rep) continue;

        // 1. Direct 1440p / 2K quality label match (e.g. @"1440p", @"1440", @"2K")
        if ([rep respondsToSelector:@selector(qualityLabel)]) {
            NSString *label = [rep performSelector:@selector(qualityLabel)];
            if ([label isKindOfClass:[NSString class]]) {
                if ([label containsString:@"1440"] || [label localizedCaseInsensitiveContainsString:@"2k"]) {
                    DashLog("Found explicit 1440p representation by label: %@", label);
                    return rep;
                }
            }
        }

        // 2. Direct pixel dimension check (width >= 1440 or height >= 2560)
        if ([rep respondsToSelector:@selector(videoSize)]) {
            NSValue *val = [rep performSelector:@selector(videoSize)];
            if (val && [val isKindOfClass:[NSValue class]]) {
                CGSize sz = [val CGSizeValue];
                if (sz.width >= 1440.0f || sz.height >= 2560.0f) {
                    DashLog("Found 1440p representation by videoSize: %.0fx%.0f", sz.width, sz.height);
                    return rep;
                }
            }
        }

        // 3. Size selector check
        if ([rep respondsToSelector:@selector(size)]) {
            NSValue *val = [rep performSelector:@selector(size)];
            if (val && [val isKindOfClass:[NSValue class]]) {
                CGSize sz = [val CGSizeValue];
                if (sz.width >= 1440.0f || sz.height >= 2560.0f) {
                    DashLog("Found 1440p representation by size: %.0fx%.0f", sz.width, sz.height);
                    return rep;
                }
            }
        }

        // 4. Bitrate / Bandwidth comparison (1440p streams have highest bitrate in manifest)
        uint64_t bw = 0;
        if ([rep respondsToSelector:@selector(bandwidth)]) {
            bw = (uint64_t)[(NSNumber *)[rep performSelector:@selector(bandwidth)] unsignedLongLongValue];
        } else if ([rep respondsToSelector:@selector(bitrate)]) {
            bw = (uint64_t)[(NSNumber *)[rep performSelector:@selector(bitrate)] unsignedLongLongValue];
        }

        if (bw > maxMetric) {
            maxMetric = bw;
            bestRep = rep;
        }
    }

    return bestRep ?: representations.firstObject;
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

// Original function pointers
static id (*orig_selectQualityFromRepsWithBandwidth)(id self, SEL _cmd, NSArray *reps, uint64_t bw) = NULL;
static id (*orig_selectQualityFromRepsSeqBandwidth)(id self, SEL _cmd, NSArray *reps, id seqIndices, uint64_t bw) = NULL;
static id (*orig_selectQualityFromRepsFetchSizes)(id self, SEL _cmd, NSArray *reps, id sizes, id seqIndexes) = NULL;
static id (*orig_selectQuality)(id self, SEL _cmd) = NULL;
static id (*orig_selectQualitySingle)(id self, SEL _cmd, id arg1) = NULL;

static id Hook_SelectQualityFromRepsWithBandwidth(id self, SEL _cmd, NSArray *representations, uint64_t bandwidth) {
    id chosen = SelectHighestRepresentation(representations);
    if (chosen) {
        return chosen;
    }
    if (orig_selectQualityFromRepsWithBandwidth) {
        return orig_selectQualityFromRepsWithBandwidth(self, _cmd, representations, bandwidth);
    }
    return representations.firstObject;
}

static id Hook_SelectQualityFromRepsSeqBandwidth(id self, SEL _cmd, NSArray *representations, id seqIndices, uint64_t bandwidth) {
    id chosen = SelectHighestRepresentation(representations);
    if (chosen) {
        return chosen;
    }
    if (orig_selectQualityFromRepsSeqBandwidth) {
        return orig_selectQualityFromRepsSeqBandwidth(self, _cmd, representations, seqIndices, bandwidth);
    }
    return representations.firstObject;
}

static id Hook_SelectQualityFromRepsFetchSizes(id self, SEL _cmd, NSArray *representations, id sizes, id seqIndexes) {
    id chosen = SelectHighestRepresentation(representations);
    if (chosen) {
        return chosen;
    }
    if (orig_selectQualityFromRepsFetchSizes) {
        return orig_selectQualityFromRepsFetchSizes(self, _cmd, representations, sizes, seqIndexes);
    }
    return representations.firstObject;
}

static id Hook_SelectQuality(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(representationsForVideoTrack)]) {
        NSArray *reps = [self performSelector:@selector(representationsForVideoTrack)];
        id chosen = SelectHighestRepresentation(reps);
        if (chosen) return chosen;
    }
    if (orig_selectQuality) {
        return orig_selectQuality(self, _cmd);
    }
    return nil;
}

static id Hook_SelectQualitySingle(id self, SEL _cmd, id arg1) {
    if ([arg1 isKindOfClass:[NSArray class]]) {
        id chosen = SelectHighestRepresentation((NSArray *)arg1);
        if (chosen) return chosen;
    }
    if (orig_selectQualitySingle) {
        return orig_selectQualitySingle(self, _cmd, arg1);
    }
    return arg1;
}

// Bypasses representation pruning so 1440p representations are never discarded
static id Hook_PruneQualitiesNoOp(id self, SEL _cmd, id qualities) {
    // Return all qualities unpruned
    return qualities;
}

static id Hook_PruneRepsNoOp(id self, SEL _cmd, id reps, id config) {
    // Return all representations unpruned
    return reps;
}

// Forces playerSize and viewPortSize to report 1440x2560 dimensions
static CGSize Hook_Return1440pSize(id self, SEL _cmd) {
    return CGSizeMake(1440.0f, 2560.0f);
}

// Disables playerSizePruner instance creation
static id Hook_ReturnNil(id self, SEL _cmd) {
    return nil;
}

// Prevents skipping high quality representations on Wi-Fi or cellular
static BOOL Hook_ReturnNO(id self, SEL _cmd) {
    return NO;
}

// Disables bandwidth resolution capping
static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

// Returns UserSelectedQualityHigh (1)
static NSInteger Hook_ReturnUserSelectedQualityHigh(id self, SEL _cmd) {
    return 1;
}

// Selects 1440p representation as default
static id Hook_DefaultVideoRepresentation(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(representationsForVideoTrack)]) {
        NSArray *reps = [self performSelector:@selector(representationsForVideoTrack)];
        id highest = SelectHighestRepresentation(reps);
        if (highest) return highest;
    }
    if ([self respondsToSelector:@selector(_representationsForVideoTrack)]) {
        NSArray *reps = [self performSelector:@selector(_representationsForVideoTrack)];
        id highest = SelectHighestRepresentation(reps);
        if (highest) return highest;
    }
    return nil;
}

// ============================================================================
// Class Hook Installation
// ============================================================================

static void SwizzleQualitySelectors(void) {
    const char *selectorClasses[] = {
        "FNFDashDefaultQualitySelector",
        "FNFDashABRPlayerSizeQualitySelector",
        "FNFDashABRSizeBasedBweQualitySelector",
        "FNFDashUserSelectedQualitySelector",
        "FNFDashMultiRepUserSelectedQualitySelector",
        "FNFDashMaxQualitySelector",
        "FNFDashQualityManager",
        "IGFNFDashQualityManager",
        "FNFStitchQualityEvaluator"
    };

    for (size_t i = 0; i < sizeof(selectorClasses) / sizeof(selectorClasses[0]); i++) {
        Class cls = objc_getClass(selectorClasses[i]);
        if (!cls) continue;

        SwizzleBoth(cls, sel_registerName("selectQualityFromRepresentations:withAvailableBandwidth:"),
                    (IMP)Hook_SelectQualityFromRepsWithBandwidth,
                    (IMP *)&orig_selectQualityFromRepsWithBandwidth, "@@:@Q");

        SwizzleBoth(cls, sel_registerName("selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                    (IMP)Hook_SelectQualityFromRepsSeqBandwidth,
                    (IMP *)&orig_selectQualityFromRepsSeqBandwidth, "@@:@@Q");

        SwizzleBoth(cls, sel_registerName("selectQualityFromRepresentations:fetchSizesInBytes:sequenceIndexes:"),
                    (IMP)Hook_SelectQualityFromRepsFetchSizes,
                    (IMP *)&orig_selectQualityFromRepsFetchSizes, "@@:@@@");

        SwizzleBoth(cls, sel_registerName("selectQuality"),
                    (IMP)Hook_SelectQuality,
                    (IMP *)&orig_selectQuality, "@@:");

        SwizzleBoth(cls, sel_registerName("selectQuality:"),
                    (IMP)Hook_SelectQualitySingle,
                    (IMP *)&orig_selectQualitySingle, "@@:@");
    }
}

static void SwizzlePrunersAndConfig(void) {
    // 1. Bypass Player Size Pruning in FNFDashPlayerSizePruner
    Class prunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (prunerCls) {
        SwizzleBoth(prunerCls, sel_registerName("pruneQualities:"), (IMP)Hook_PruneQualitiesNoOp, NULL, "@@:@");
        SwizzleBoth(prunerCls, sel_registerName("pruneReps:withConfig:"), (IMP)Hook_PruneRepsNoOp, NULL, "@@:@@");
        SwizzleBoth(prunerCls, sel_registerName("_shouldSkipRepAOC:isOnWifi:"), (IMP)Hook_ReturnNO, NULL, "B@:@B");
    }

    // 2. Force 1440p Viewport & Player Size in FNFDashConfig & Metadata
    Class configCls = objc_getClass("FNFDashConfig");
    if (configCls) {
        SwizzleBoth(configCls, sel_registerName("playerSize"), (IMP)Hook_Return1440pSize, NULL, "{CGSize=dd}@:");
        SwizzleBoth(configCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pSize, NULL, "{CGSize=dd}@:");
        SwizzleBoth(configCls, sel_registerName("playerSizePruner"), (IMP)Hook_ReturnNil, NULL, "@@:");
        SwizzleBoth(configCls, sel_registerName("userSelectedQuality"), (IMP)Hook_ReturnUserSelectedQualityHigh, NULL, "q@:");
        SwizzleBoth(configCls, sel_registerName("UserSelectedQuality"), (IMP)Hook_ReturnUserSelectedQualityHigh, NULL, "q@:");
        SwizzleBoth(configCls, sel_registerName("isUserDataSaverModeEnabled"), (IMP)Hook_ReturnNO, NULL, "B@:");
        SwizzleBoth(configCls, sel_registerName("bandwidthLimitedResolutionsDisabled"), (IMP)Hook_ReturnYES, NULL, "B@:");
        SwizzleBoth(configCls, sel_registerName("BandwidthLimitedResolutionsDisabled"), (IMP)Hook_ReturnYES, NULL, "B@:");
    }

    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SwizzleBoth(metaCls, sel_registerName("playerSize"), (IMP)Hook_Return1440pSize, NULL, "{CGSize=dd}@:");
        SwizzleBoth(metaCls, sel_registerName("viewPortSize"), (IMP)Hook_Return1440pSize, NULL, "{CGSize=dd}@:");
    }

    // 3. Force 1440p Default Representation in Playlist Managers
    const char *playlistClasses[] = {
        "FNFDashPlaylistManager",
        "FNFDashManifestMetadata",
        "IGFNFSelectedQualityProvider"
    };

    for (size_t i = 0; i < sizeof(playlistClasses) / sizeof(playlistClasses[0]); i++) {
        Class cls = objc_getClass(playlistClasses[i]);
        if (!cls) continue;

        SwizzleBoth(cls, sel_registerName("defaultVideoRepresentation"), (IMP)Hook_DefaultVideoRepresentation, NULL, "@@:");
        SwizzleBoth(cls, sel_registerName("_defaultVideoRepresentation"), (IMP)Hook_DefaultVideoRepresentation, NULL, "@@:");
        SwizzleBoth(cls, sel_registerName("selectedRepresentation"), (IMP)Hook_DefaultVideoRepresentation, NULL, "@@:");
        SwizzleBoth(cls, sel_registerName("isUserDataSaverModeEnabled"), (IMP)Hook_ReturnNO, NULL, "B@:");
    }
}

static void ApplyAllDash1440pSwizzles(void) {
    static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_mutex);

    SwizzleQualitySelectors();
    SwizzlePrunersAndConfig();

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
        NSLog(@"[InstagramDash1440p] Maximum Bitrate / 1440p Representation Selector Active");

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
