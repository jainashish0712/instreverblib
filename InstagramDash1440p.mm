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
#import <cstring>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <dlfcn.h>
#import <CoreMedia/CoreMedia.h>
#import "fishhook.h"
#import "InstagramDash1440p.h"

NSString * const kInstagramDash1440pStateDidChangeNotification = @"kInstagramDash1440pStateDidChangeNotification";

static BOOL g_dash1440pEnabled = YES;
static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1440p";
static NSString *g_currentResolution = @"";
static NSString *g_currentRepresentationId = @"ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

// ============================================================================
// Zero-Overhead Logging Stub (Disabled for Stutter-Free 1440p Playback)
// ============================================================================

#define DashLog(...) do {} while(0)

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
// Representation Introspection Helpers & Unpacking
// ============================================================================

static id ExtractRepresentationFromObject(id obj) {
    if (!obj) return nil;

    // Check if obj itself is a representation
    if ([obj respondsToSelector:@selector(representationId)] ||
        [obj respondsToSelector:@selector(videoSize)] ||
        [obj respondsToSelector:@selector(bandwidth)]) {
        return obj;
    }

    // Check selection metadata wrappers
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

    // Safe KVC fallback
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
        if (tr == 1) return YES; // In FNF, track 1 is Audio, track 0 is Video
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
        if ([actual respondsToSelector:@selector(size)]) {
            sz = ((CGSize (*)(id, SEL))objc_msgSend)(actual, @selector(size));
        }
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
        uint64_t bw = ((uint64_t (*)(id, SEL))objc_msgSend)(actual, @selector(bandwidth));
        if (bw > 0) return bw;
    }
    if ([actual respondsToSelector:@selector(bitrate)]) {
        uint64_t br = ((uint64_t (*)(id, SEL))objc_msgSend)(actual, @selector(bitrate));
        if (br > 0) return br;
    }
    if ([actual respondsToSelector:@selector(bandwidthInBitsPerSecond)]) {
        uint64_t bw = ((uint64_t (*)(id, SEL))objc_msgSend)(actual, @selector(bandwidthInBitsPerSecond));
        if (bw > 0) return bw;
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
// State & Telemetry Updates
// ============================================================================

static void UpdateActiveRepresentation(id rep, BOOL isPrefetch) {
    if (!rep || IsAudioRepresentation(rep)) return;
    id actual = ExtractRepresentationFromObject(rep);
    if (!actual || IsAudioRepresentation(actual)) return;

    CGSize sz = GetRepresentationPixelDimensions(actual);
    CGFloat minDim = MIN(sz.width, sz.height);
    CGFloat maxDim = MAX(sz.width, sz.height);
    uint64_t pixels = (uint64_t)(sz.width * sz.height);
    NSString *repId = GetRepresentationId(actual) ?: @"unknown";
    NSString *encodingTag = GetRepresentationEncodingTag(actual);

    BOOL is1440 = (minDim > 1080.0f || maxDim > 1920.0f || pixels > 2200000ULL ||
                   (repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"1440"] || [repId containsString:@"2k"])) ||
                   (encodingTag && ([encodingTag containsString:@"1440"] || [encodingTag containsString:@"2k"])));

    BOOL is1080 = (!is1440 && (minDim >= 1000.0f || maxDim >= 1800.0f || pixels >= 1900000ULL ||
                   (repId && [repId containsString:@"1080"]) ||
                   (encodingTag && [encodingTag containsString:@"1080"])));

    NSString *quality = is1440 ? @"1440p" : (is1080 ? @"1080p" : [NSString stringWithFormat:@"%.0fp", minDim > 0.0f ? minDim : 1080.0f]);
    NSString *resolution = (sz.width > 0.0f && sz.height > 0.0f) ? [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height] : (is1440 ? @"1440x2560" : @"1080x1920");

    if (isPrefetch) {
        DashLog(@"[Prefetch Engine] Queued offscreen chunk: %@ (%@, %@, %llu bps)",
                quality, repId, resolution, bw);
        return;
    }

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
        DashLog(@"[Active Playback] Representation locked: %@ (%@, %@, %llu bps)",
                quality, repId, resolution, bw);
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
        CGFloat minDim = MIN(sz.width, sz.height);
        CGFloat maxDim = MAX(sz.width, sz.height);
        uint64_t pixels = (uint64_t)(sz.width * sz.height);
        uint64_t bw = GetRepresentationBitrate(rep);
        NSString *repId = GetRepresentationId(rep);
        NSString *encodingTag = GetRepresentationEncodingTag(rep);

        BOOL is1440 = (minDim > 1080.0f || maxDim > 1920.0f || pixels > 2200000ULL ||
                       (repId && ([repId containsString:@"1539525017490074"] || [repId containsString:@"1440"] || [repId containsString:@"2k"])) ||
                       (encodingTag && ([encodingTag containsString:@"1440"] || [encodingTag containsString:@"2k"])));

        BOOL is1080 = (!is1440 && (minDim >= 1000.0f || maxDim >= 1800.0f || pixels >= 1900000ULL ||
                       (repId && [repId containsString:@"1080"]) ||
                       (encodingTag && [encodingTag containsString:@"1080"])));

        DashLog(@"[Quality Selector] Candidate rep: %@ (%.0fx%.0f, %llu bps, is1440=%d, is1080=%d)",
                repId, sz.width, sz.height, bw, is1440, is1080);

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
    return chosen;
}

// ============================================================================
// Objective-C Swizzle Helpers & Method Introspection
// ============================================================================

static void LogClassMethods(Class cls) {
    (void)cls;
}

static BOOL SafeSwizzleMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        DashLog(@"[Swizzle FAILED] -[%s %s] does not exist!", class_getName(cls), sel_getName(sel));
        return NO;
    }

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;

    if (origImp && !*origImp) {
        *origImp = orig;
    }

    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(cls, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }
    DashLog(@"[Swizzle OK] Successfully swizzled -[%s %s]", class_getName(cls), sel_getName(sel));
    return YES;
}

// ============================================================================
// Quality Selector General Handler (Dispatches for any FNF Quality Selector)
// ============================================================================

static id HandleQualitySelection(id self, SEL _cmd, IMP origImp, const char *className) {
    id chosen = nil;
    if (origImp) {
        chosen = ((id (*)(id, SEL))origImp)(self, _cmd);
    }

    DashLog(@"[%s] selectQuality invoked, standard result: %@", className, chosen);

    if (!InstagramDash1440p_IsEnabled()) {
        if (chosen) UpdateActiveRepresentation(chosen, NO);
        return chosen;
    }

    // Attempt to locate candidate representations from selector instance
    NSArray *reps = nil;
    if ([self respondsToSelector:@selector(representations)]) {
        @try {
            reps = [self valueForKey:@"representations"];
        } @catch (NSException *e) {}
    }
    if (!reps && [self respondsToSelector:@selector(playlist)]) {
        @try {
            id playlist = [self valueForKey:@"playlist"];
            if (playlist && [playlist respondsToSelector:@selector(representationsForTrack:)]) {
                reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 0);
            }
        } @catch (NSException *e) {}
    }
    if (!reps) {
        Ivar ivar = class_getInstanceVariable([self class], "_playlist");
        if (!ivar) ivar = class_getInstanceVariable([self class], "playlist");
        if (ivar) {
            id playlist = object_getIvar(self, ivar);
            if (playlist && [playlist respondsToSelector:@selector(representationsForTrack:)]) {
                reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(playlist, @selector(representationsForTrack:), 0);
            }
        }
    }
    if (!reps) {
        Ivar ivar = class_getInstanceVariable([self class], "_representations");
        if (!ivar) ivar = class_getInstanceVariable([self class], "representations");
        if (ivar) {
            reps = (NSArray *)object_getIvar(self, ivar);
        }
    }

    if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
        BOOL isPrefetch = (strstr(className, "Prefetch") != NULL);
        id targetRep = SelectTargetRepresentation(reps, isPrefetch);
        if (targetRep) {
            DashLog(@"[%s] Forcing target quality representation: %@", className, targetRep);
            if (!isPrefetch) {
                UpdateActiveRepresentation(targetRep, NO);
            }
            return targetRep;
        }
    } else {
        DashLog(@"[%s] Could not extract candidate representations array; tracking standard result: %@", className, chosen);
        BOOL isPrefetch = (strstr(className, "Prefetch") != NULL);
        if (chosen && !isPrefetch) {
            UpdateActiveRepresentation(chosen, NO);
        }
    }

    return chosen;
}

// Dedicated function pointers and hooks for each quality selector class
static id (*orig_ABRQualitySelector_selectQuality)(id self, SEL _cmd) = NULL;
static id Hook_ABRQualitySelector_SelectQuality(id self, SEL _cmd) {
    return HandleQualitySelection(self, _cmd, (IMP)orig_ABRQualitySelector_selectQuality, "FNFDashABRQualitySelector");
}

static id (*orig_DefaultQualitySelector_selectQuality)(id self, SEL _cmd) = NULL;
static id Hook_DefaultQualitySelector_SelectQuality(id self, SEL _cmd) {
    return HandleQualitySelection(self, _cmd, (IMP)orig_DefaultQualitySelector_selectQuality, "FNFDashDefaultQualitySelector");
}

static id (*orig_QualitySelector_selectQuality)(id self, SEL _cmd) = NULL;
static id Hook_QualitySelector_SelectQuality(id self, SEL _cmd) {
    return HandleQualitySelection(self, _cmd, (IMP)orig_QualitySelector_selectQuality, "FNFDashQualitySelector");
}

static id (*orig_PrefetchQualitySelector_selectQuality)(id self, SEL _cmd) = NULL;
static id Hook_PrefetchQualitySelector_SelectQuality(id self, SEL _cmd) {
    return HandleQualitySelection(self, _cmd, (IMP)orig_PrefetchQualitySelector_selectQuality, "FNFDashPrefetchQualitySelector");
}

static id (*orig_LiveQualitySelector_selectQuality)(id self, SEL _cmd) = NULL;
static id Hook_LiveQualitySelector_SelectQuality(id self, SEL _cmd) {
    return HandleQualitySelection(self, _cmd, (IMP)orig_LiveQualitySelector_selectQuality, "FNFDashLiveQualitySelector");
}

// Hook for FNFDashABRQualitySelector _selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:
static id (*orig_ABR_selectQualitySeqIndices)(id self, SEL _cmd, NSArray *representations, std::vector<int> seqIndices, double bandwidth) = NULL;

static id Hook_ABR_SelectQualitySeqIndices(id self, SEL _cmd, NSArray *representations, std::vector<int> seqIndices, double bandwidth) {
    DashLog(@"[FNFDashABRQualitySelector] _selectQualityFromRepresentations:sequenceIndices:... called with %lu reps", (unsigned long)representations.count);
    if (InstagramDash1440p_IsEnabled() && representations && [representations isKindOfClass:[NSArray class]] && representations.count > 0) {
        if (!IsAudioRepresentation(representations.firstObject)) {
            id chosen = SelectTargetRepresentation(representations, NO);
            if (chosen) {
                UpdateActiveRepresentation(chosen, NO);
                return chosen;
            }
        }
    }
    if (orig_ABR_selectQualitySeqIndices) {
        return orig_ABR_selectQualitySeqIndices(self, _cmd, representations, seqIndices, bandwidth);
    }
    return representations.firstObject;
}

// Hook for FNFDashPlayerSizePruner
static NSArray * (*orig_sizePruner_pruneQualities)(id self, SEL _cmd, NSArray *qualities) = NULL;

static NSArray * Hook_PruneQualitiesNoOp(id self, SEL _cmd, NSArray *qualities) {
    DashLog(@"[FNFDashPlayerSizePruner] pruneQualities: called with %lu qualities", (unsigned long)qualities.count);
    if (!InstagramDash1440p_IsEnabled() && orig_sizePruner_pruneQualities) {
        return orig_sizePruner_pruneQualities(self, _cmd, qualities);
    }
    return qualities;
}

// Hook for FNFDashPlaylist representationsForTrack:
static NSArray * (*orig_playlist_representationsForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static NSArray * Hook_Playlist_RepresentationsForTrack(id self, SEL _cmd, NSInteger track) {
    NSArray *origReps = nil;
    if (orig_playlist_representationsForTrack) {
        origReps = orig_playlist_representationsForTrack(self, _cmd, track);
    }
    if (!InstagramDash1440p_IsEnabled() || !origReps || ![origReps isKindOfClass:[NSArray class]] || origReps.count <= 1) {
        return origReps;
    }

    if (IsAudioRepresentation(origReps.firstObject)) {
        return origReps;
    }

    id chosen = SelectTargetRepresentation(origReps, YES);
    if (chosen) {
        DashLog(@"[FNFDashPlaylist] representationsForTrack:%ld filtered to target quality: %@", (long)track, chosen);
        return @[ chosen ];
    }
    return origReps;
}

// Hook for FNFDashPlaylist _representationsForVideoTrack
static NSArray * (*orig_playlist_representationsForVideoTrack)(id self, SEL _cmd) = NULL;

static NSArray * Hook_Playlist_RepresentationsForVideoTrack(id self, SEL _cmd) {
    NSArray *origReps = nil;
    if (orig_playlist_representationsForVideoTrack) {
        origReps = orig_playlist_representationsForVideoTrack(self, _cmd);
    }
    if (!InstagramDash1440p_IsEnabled() || !origReps || ![origReps isKindOfClass:[NSArray class]] || origReps.count <= 1) {
        return origReps;
    }

    id chosen = SelectTargetRepresentation(origReps, YES);
    if (chosen) {
        DashLog(@"[FNFDashPlaylist] _representationsForVideoTrack filtered to target quality: %@", chosen);
        return @[ chosen ];
    }
    return origReps;
}

// Hook for FNFDashPlaylist defaultRepresentationForTrack:
static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    DashLog(@"[FNFDashPlaylist] defaultRepresentationForTrack:%ld invoked", (long)track);
    if (InstagramDash1440p_IsEnabled()) {
        NSArray *reps = nil;
        if ([self respondsToSelector:@selector(representationsForTrack:)]) {
            reps = ((NSArray *(*)(id, SEL, NSInteger))objc_msgSend)(self, @selector(representationsForTrack:), track);
        }
        if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0 && !IsAudioRepresentation(reps.firstObject)) {
            id chosen = SelectTargetRepresentation(reps, YES);
            if (chosen) {
                DashLog(@"[FNFDashPlaylist] defaultRepresentationForTrack:%ld (Video) forced: %@", (long)track, chosen);
                return chosen;
            }
        }
    }
    if (orig_playlist_defaultRepresentationForTrack) {
        return orig_playlist_defaultRepresentationForTrack(self, _cmd, track);
    }
    return nil;
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
        // Enforce Apple Silicon hardware video decoder specification for high-bitrate VP9 streams
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
            // Guarantee real-time presentation deadlines to prevent frame dropping during 1440p DASH streaming
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

// ----------------------------------------------------------------------------
// FNF VP9 Session Decompression Hook
// ----------------------------------------------------------------------------

static id (*orig_vp9x_init)(id self, SEL _cmd, id delegate, void *formatDesc, CGSize videoSize, BOOL async, void *config, id pcm, NSError **error) = NULL;

static id Hook_FNFDecompressionSessionForVP9X_Init(id self, SEL _cmd, id delegate, void *formatDesc, CGSize videoSize, BOOL async, void *config, id pcm, NSError **error) {
    if (config) {
        uint8_t *cfg = (uint8_t *)config;
        // Verified FNFDecompressionConfig byte offsets from FBSharedFramework disassembly:
        // [0x59] enableVTForVP9: 1 -> Selects native VideoToolbox hardware decode path
        // [0x58] enableVTHWAcceleratedDetection: 1 -> Enables hardware engine probing
        // [0x74] fixVP9DecoderRegistrationRace: 1 -> Prevents concurrent decoder init race
        // [0x38] enableVP9VTDecodingDimensionCheck: 0 -> Bypass resolution cap for 1440p
        // [0x33] disableVTAsynchronousDecompression: 0 -> Keep async hardware decompression enabled
        // [0x34] disableVT1xRealTimePlayback: 0 -> Keep real-time 60fps presentation
        // [0x35] disableVTTemporalProcessing: 0
        cfg[0x59] = 1;
        cfg[0x58] = 1;
        cfg[0x74] = 1;
        cfg[0x38] = 0;
        cfg[0x33] = 0;
        cfg[0x34] = 0;
        cfg[0x35] = 0;
    }

    if (orig_vp9x_init) {
        return orig_vp9x_init(self, _cmd, delegate, formatDesc, videoSize, async, config, pcm, error);
    }
    return nil;
}

static BOOL (*orig_vp9x_usesSoftwareDecoder)(id self, SEL _cmd) = NULL;

static BOOL Hook_FNFDecompressionSessionForVP9X_UsesSoftwareDecoder(id self, SEL _cmd) {
    // Hardware accelerated via VideoToolbox
    return NO;
}

static BOOL Hook_ReturnNO(id self, SEL _cmd, id rep, BOOL isIntentional) {
    return NO;
}

// Hooks for IGFNFSelectedQualityProvider
static void (*orig_qualityProvider_videoQualitySelected)(id self, SEL _cmd, id rep, id meta, NSInteger track) = NULL;

static void Hook_QualityProvider_VideoQualitySelected(id self, SEL _cmd, id rep, id meta, NSInteger track) {
    DashLog(@"[IGFNFSelectedQualityProvider] videoQualitySelected: track=%ld rep=%@", (long)track, rep);
    if (rep) {
        BOOL isIntentional = YES;
        if (meta) {
            if ([meta respondsToSelector:@selector(isIntentional)]) {
                isIntentional = ((BOOL (*)(id, SEL))objc_msgSend)(meta, @selector(isIntentional));
            } else {
                @try {
                    id val = [meta valueForKey:@"isIntentional"];
                    if (val && [val respondsToSelector:@selector(boolValue)]) {
                        isIntentional = [val boolValue];
                    }
                } @catch (NSException *e) {}
            }
        }
        if (isIntentional) {
            id actualRep = ExtractRepresentationFromObject(rep);
            if (actualRep && !IsAudioRepresentation(actualRep)) {
                UpdateActiveRepresentation(actualRep, NO);
            }
        }
    }
    if (orig_qualityProvider_videoQualitySelected) {
        orig_qualityProvider_videoQualitySelected(self, _cmd, rep, meta, track);
    }
}

static void (*orig_qualityProvider_setVideoRep)(id self, SEL _cmd, id rep) = NULL;

static void Hook_QualityProvider_SetVideoRep(id self, SEL _cmd, id rep) {
    DashLog(@"[IGFNFSelectedQualityProvider] setVideoSelectedQualityRepresentation: %@", rep);
    if (orig_qualityProvider_setVideoRep) {
        orig_qualityProvider_setVideoRep(self, _cmd, rep);
    }
}

// ============================================================================
// Swizzle Registration & Initialization
// ============================================================================

static void SwizzleDashClasses(void) {
    DashLog(@"Registering 1440p VP9 DASH hooks and analyzing runtime classes...");

    // 1. FNFDashPlayerSizePruner
    Class sizePrunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (sizePrunerCls) {
        LogClassMethods(sizePrunerCls);
        SafeSwizzleMethod(sizePrunerCls, sel_registerName("pruneQualities:"),
                          (IMP)Hook_PruneQualitiesNoOp, (IMP *)&orig_sizePruner_pruneQualities);
    } else {
        DashLog(@"[Warning] FNFDashPlayerSizePruner class not found");
    }

    // 2. FNFDashPlaylist
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        LogClassMethods(playlistCls);
        SafeSwizzleMethod(playlistCls, sel_registerName("representationsForTrack:"),
                          (IMP)Hook_Playlist_RepresentationsForTrack, (IMP *)&orig_playlist_representationsForTrack);
        SafeSwizzleMethod(playlistCls, sel_registerName("_representationsForVideoTrack"),
                          (IMP)Hook_Playlist_RepresentationsForVideoTrack, (IMP *)&orig_playlist_representationsForVideoTrack);
        SafeSwizzleMethod(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                          (IMP)Hook_Playlist_DefaultRepresentationForTrack, (IMP *)&orig_playlist_defaultRepresentationForTrack);
    } else {
        DashLog(@"[Warning] FNFDashPlaylist class not found");
    }

    // 3. Multi-Class Quality Selectors: Hook selectQuality on all known selector variants
    struct QualitySelectorBinding {
        const char *name;
        IMP hook;
        IMP *orig;
    } selectors[] = {
        {"FNFDashABRQualitySelector", (IMP)Hook_ABRQualitySelector_SelectQuality, (IMP *)&orig_ABRQualitySelector_selectQuality},
        {"FNFDashDefaultQualitySelector", (IMP)Hook_DefaultQualitySelector_SelectQuality, (IMP *)&orig_DefaultQualitySelector_selectQuality},
        {"FNFDashQualitySelector", (IMP)Hook_QualitySelector_SelectQuality, (IMP *)&orig_QualitySelector_selectQuality},
        {"FNFDashPrefetchQualitySelector", (IMP)Hook_PrefetchQualitySelector_SelectQuality, (IMP *)&orig_PrefetchQualitySelector_selectQuality},
        {"FNFDashLiveQualitySelector", (IMP)Hook_LiveQualitySelector_SelectQuality, (IMP *)&orig_LiveQualitySelector_selectQuality}
    };

    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        Class qCls = objc_getClass(selectors[i].name);
        if (qCls) {
            LogClassMethods(qCls);
            SafeSwizzleMethod(qCls, sel_registerName("selectQuality"), selectors[i].hook, selectors[i].orig);
        } else {
            DashLog(@"[Notice] %s class not loaded in runtime", selectors[i].name);
        }
    }

    // 3b. FNFDashABRQualitySelector Sequence Indices variant
    Class abrCls = objc_getClass("FNFDashABRQualitySelector");
    if (abrCls) {
        SafeSwizzleMethod(abrCls, sel_registerName("_selectQualityFromRepresentations:sequenceIndices:withAvailableBandwidth:"),
                          (IMP)Hook_ABR_SelectQualitySeqIndices, (IMP *)&orig_ABR_selectQualitySeqIndices);
        SafeSwizzleMethod(abrCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"),
                          (IMP)Hook_ReturnNO, NULL);
    }

    // 4. Force Apple VideoToolbox Hardware VP9 Decoder
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

    // 5. Active Telemetry Observers
    Class qualityProviderCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (qualityProviderCls) {
        LogClassMethods(qualityProviderCls);
        SafeSwizzleMethod(qualityProviderCls, sel_registerName("videoQualitySelected:playerMetadata:trackType:"),
                          (IMP)Hook_QualityProvider_VideoQualitySelected, (IMP *)&orig_qualityProvider_videoQualitySelected);
        SafeSwizzleMethod(qualityProviderCls, sel_registerName("setVideoSelectedQualityRepresentation:"),
                          (IMP)Hook_QualityProvider_SetVideoRep, (IMP *)&orig_qualityProvider_setVideoRep);
    }

    DashLog(@"1440p VP9 DASH hook registration pass finished");
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
        DashLog(@"==================================================================");
        DashLog(@"Initializing Ultra-HD 1440p VP9 DASH Video Engine for Instagram");
        DashLog(@"Active Reels & Feed Prefetchers: 1440p Priority, 1080p Fallback Floor");
        DashLog(@"Apple VideoToolbox VP9 Hardware/Hybrid Decoder Enabled");
        DashLog(@"==================================================================");

        HookVTDecompressionSessionCreateOnce();
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
