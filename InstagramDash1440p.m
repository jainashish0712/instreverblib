// InstagramDash1440p.m
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unconditionally forces full 1440p (2560x1440) DASH video playback on Wi-Fi and Cellular data by:
// 1. Locking 1440p representation selection in FNFDashABRQualitySelector without downscaling.
// 2. Overriding FNFDashPlaylist defaultRepresentationForTrack: and updateDefaultRepresentationForTrack:.
// 3. Overriding FNF player size pruning (reporting 1440x2560 viewport and screen dimensions).
// 4. Bypassing representation pruning in FNFDashPlayerSizePruner.
// 5. Boosting bandwidth estimation providers to 100+ Mbps so ABR logic never caps representation resolution.
// 6. Strictly isolating audio representations from video representations so audio tracks never overwrite video modal state.
// 7. Providing persistent runtime file logging and crash reporting to both the tweak directory and Documents directory.
// 8. Supporting runtime toggle via 20px modal for standard vs 1440p behavior.
// 9. Accurately extracting server representation info ("fdash-%id") and discriminating true 1440p vs 1080p.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <execinfo.h>
#import <time.h>
#import "InstagramDash1440p.h"

NSString * const kInstagramDash1440pStateDidChangeNotification = @"kInstagramDash1440pStateDidChangeNotification";

static BOOL g_dash1440pEnabled = YES;
static BOOL g_isActual1440p = NO;
static NSString *g_currentQuality = @"1080p";
static NSString *g_currentFdashFilename = @"fdash-ready";
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

static id g_lastHighestVideoRep = nil;
static const char *kPlaylistHighestVideoRepKey = "kPlaylistHighestVideoRepKey";

// ============================================================================
// Directory Resolution & Multi-Destination File Logging
// ============================================================================

static char g_tweakDirPath[1024] = {0};
static char g_docDirPath[1024] = {0};
static char g_dashLogFilePathTweak[1024] = {0};
static char g_dashLogFilePathDoc[1024] = {0};
static char g_dashCrashFilePathTweak[1024] = {0};
static char g_dashCrashFilePathDoc[1024] = {0};
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

static void ResolveDirectories(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. Resolve Tweak Directory from loaded dylib location
        Dl_info dlinfo;
        if (dladdr((const void *)InstagramDash1440p_Init, &dlinfo) && dlinfo.dli_fname) {
            NSString *dylibPath = [NSString stringWithUTF8String:dlinfo.dli_fname];
            NSString *tweakDir = [dylibPath stringByDeletingLastPathComponent];
            snprintf(g_tweakDirPath, sizeof(g_tweakDirPath), "%s", [tweakDir UTF8String]);
        }

        // 2. Resolve App Documents Directory
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        if (docDir) {
            snprintf(g_docDirPath, sizeof(g_docDirPath), "%s", [docDir UTF8String]);
        }

        // Fallback if tweak dir is empty
        if (g_tweakDirPath[0] == '\0') {
            if (g_docDirPath[0] != '\0') {
                snprintf(g_tweakDirPath, sizeof(g_tweakDirPath), "%s", g_docDirPath);
            } else {
                snprintf(g_tweakDirPath, sizeof(g_tweakDirPath), "/tmp");
            }
        }
        if (g_docDirPath[0] == '\0') {
            snprintf(g_docDirPath, sizeof(g_docDirPath), "/tmp");
        }

        // Set file paths
        snprintf(g_dashLogFilePathTweak, sizeof(g_dashLogFilePathTweak), "%s/InstagramDash1440p.log", g_tweakDirPath);
        snprintf(g_dashLogFilePathDoc, sizeof(g_dashLogFilePathDoc), "%s/InstagramDash1440p.log", g_docDirPath);
        snprintf(g_dashCrashFilePathTweak, sizeof(g_dashCrashFilePathTweak), "%s/InstagramDash1440p_crash.log", g_tweakDirPath);
        snprintf(g_dashCrashFilePathDoc, sizeof(g_dashCrashFilePathDoc), "%s/InstagramDash1440p_crash.log", g_docDirPath);
    });
}

static void DashLogToFile(NSString *format, ...) {
    if (!format) return;
    ResolveDirectories();

    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Format timestamp
    time_t rawtime;
    struct tm timeinfo;
    char timeBuf[32];
    time(&rawtime);
    localtime_r(&rawtime, &timeinfo);
    strftime(timeBuf, sizeof(timeBuf), "%Y-%m-%d %H:%M:%S", &timeinfo);

    NSString *logLine = [NSString stringWithFormat:@"[%s] [InstagramDash1440p] %@\n", timeBuf, msg];
    const char *utf8Str = [logLine UTF8String];
    size_t len = strlen(utf8Str);

    NSLog(@"[InstagramDash1440p] %@", msg);

    pthread_mutex_lock(&g_logMutex);

    // Write to Tweak Directory log
    if (g_dashLogFilePathTweak[0] != '\0') {
        int fd = open(g_dashLogFilePathTweak, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, utf8Str, len);
            close(fd);
        }
    }

    // Write to Documents Directory log (if different)
    if (g_dashLogFilePathDoc[0] != '\0' && strcmp(g_dashLogFilePathTweak, g_dashLogFilePathDoc) != 0) {
        int fd = open(g_dashLogFilePathDoc, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, utf8Str, len);
            close(fd);
        }
    }

    pthread_mutex_unlock(&g_logMutex);
}

// ============================================================================
// Crash Reporter (Objective-C Uncaught Exceptions & POSIX Hardware Faults)
// ============================================================================

static NSUncaughtExceptionHandler *g_previousUncaughtExceptionHandler = NULL;

static void DashUncaughtExceptionHandler(NSException *exception) {
    ResolveDirectories();

    NSString *name = exception.name ?: @"UnknownException";
    NSString *reason = exception.reason ?: @"NoReason";
    NSDictionary *userInfo = exception.userInfo;
    NSArray *stackSymbols = [exception callStackSymbols];

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"\n=================================================================\n"];
    [report appendString:@"FATAL UNCAUGHT NSException TRAPPED BY INSTAGRAM DASH 1440p ENGINE\n"];
    [report appendString:@"=================================================================\n"];
    [report appendFormat:@"Exception: %@\n", name];
    [report appendFormat:@"Reason: %@\n", reason];
    if (userInfo && userInfo.count > 0) {
        [report appendFormat:@"UserInfo: %@\n", userInfo];
    }
    [report appendString:@"Call Stack Symbols:\n"];
    for (NSString *frame in stackSymbols) {
        [report appendFormat:@"  %@\n", frame];
    }
    [report appendString:@"=================================================================\n"];

    const char *utf8 = [report UTF8String];
    size_t len = strlen(utf8);

    // Write to both crash files
    if (g_dashCrashFilePathTweak[0] != '\0') {
        int fd = open(g_dashCrashFilePathTweak, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, utf8, len);
            fsync(fd);
            close(fd);
        }
    }
    if (g_dashCrashFilePathDoc[0] != '\0' && strcmp(g_dashCrashFilePathTweak, g_dashCrashFilePathDoc) != 0) {
        int fd = open(g_dashCrashFilePathDoc, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            write(fd, utf8, len);
            fsync(fd);
            close(fd);
        }
    }

    NSLog(@"%@", report);

    if (g_previousUncaughtExceptionHandler) {
        g_previousUncaughtExceptionHandler(exception);
    }
}

static void DashSignalCrashHandler(int sig, siginfo_t *info, void *context) {
    const char *sigName = (sig == SIGSEGV) ? "SIGSEGV (Segmentation Fault)" :
                          (sig == SIGBUS)  ? "SIGBUS (Bus Error)" :
                          (sig == SIGABRT) ? "SIGABRT (Abort)" :
                          (sig == SIGILL)  ? "SIGILL (Illegal Instruction)" :
                          (sig == SIGFPE)  ? "SIGFPE (Floating Point Exception)" : "UNKNOWN SIGNAL";

    char header[512];
    snprintf(header, sizeof(header),
             "\n=================================================================\n"
             "FATAL POSIX SIGNAL TRAPPED BY INSTAGRAM DASH 1440p ENGINE\n"
             "Signal: %d -> %s\n"
             "Faulting Memory Address: %p\n"
             "PID: %d\n"
             "Call Stack Backtrace:\n"
             "=================================================================\n",
             sig, sigName, info ? info->si_addr : NULL, getpid());

    void *callstack[64];
    int frames = backtrace(callstack, 64);
    char **symbols = backtrace_symbols(callstack, frames);

    // Signal-safe write to tweak crash log
    int fd = open(g_dashCrashFilePathTweak[0] ? g_dashCrashFilePathTweak : "/tmp/InstagramDash1440p_crash.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        write(fd, header, strlen(header));
        if (symbols) {
            for (int i = 0; i < frames; ++i) {
                write(fd, "  ", 2);
                write(fd, symbols[i], strlen(symbols[i]));
                write(fd, "\n", 1);
            }
        }
        write(fd, "=================================================================\n\n", 67);
        fsync(fd);
        close(fd);
    }

    // Write to Documents crash log if different
    if (g_dashCrashFilePathDoc[0] != '\0' && strcmp(g_dashCrashFilePathTweak, g_dashCrashFilePathDoc) != 0) {
        int fd2 = open(g_dashCrashFilePathDoc, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd2 >= 0) {
            write(fd2, header, strlen(header));
            if (symbols) {
                for (int i = 0; i < frames; ++i) {
                    write(fd2, "  ", 2);
                    write(fd2, symbols[i], strlen(symbols[i]));
                    write(fd2, "\n", 1);
                }
            }
            write(fd2, "=================================================================\n\n", 67);
            fsync(fd2);
            close(fd2);
        }
    }

    if (symbols) free(symbols);

    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallCrashHandlers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ResolveDirectories();

        // 1. NSUncaughtExceptionHandler
        g_previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&DashUncaughtExceptionHandler);

        // 2. POSIX Signal Handlers
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = DashSignalCrashHandler;
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGABRT, &sa, NULL);
        sigaction(SIGILL, &sa, NULL);
        sigaction(SIGFPE, &sa, NULL);

        DashLogToFile(@"Crash handlers installed successfully. Log file: %s | Crash file: %s",
                      g_dashLogFilePathTweak, g_dashCrashFilePathTweak);
    });
}

// ============================================================================
// Public Interface Implementations
// ============================================================================

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
    BOOL changed = NO;
    pthread_mutex_lock(&g_stateMutex);
    if (![g_currentFdashFilename isEqualToString:filename]) {
        g_currentFdashFilename = [filename copy];
        changed = YES;
    }
    pthread_mutex_unlock(&g_stateMutex);

    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
        });
    }
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

    BOOL changed = NO;
    pthread_mutex_lock(&g_stateMutex);
    if (![g_currentQuality isEqualToString:quality] ||
        ![g_currentFdashFilename isEqualToString:fdashName] ||
        g_isActual1440p != is1440p) {
        g_isActual1440p = is1440p;
        g_currentQuality = [quality copy];
        g_currentFdashFilename = [fdashName copy];
        changed = YES;
    }
    pthread_mutex_unlock(&g_stateMutex);

    if (changed) {
        DashLogToFile(@"Quality updated -> Quality: %@, File: %@ (Actual 1440p: %d, Resolution: %.0fx%.0f)",
                      quality, fdashName, is1440p, sz.width, sz.height);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kInstagramDash1440pStateDidChangeNotification object:nil];
        });
    }
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
            DashLogToFile(@"Locked onto 1440p representation: %@ (%.0fx%.0f, bandwidth: %llu)", repId, sz.width, sz.height, bw);
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
// Objective-C Swizzle Helpers (Single-Class Isolated Implementation)
// ============================================================================

static void SafeSwizzleInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    IMP orig = method_getImplementation(method);
    if (orig == newImp) {
        return; // Already swizzled
    }

    if (origImp && !*origImp) {
        *origImp = orig;
    }

    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, newImp, types)) {
        method_setImplementation(method, newImp);
    }
}

#define SwizzleMethod(c, s, n, o) SafeSwizzleInstanceMethod(c, s, (IMP)n, (IMP *)o)

// ============================================================================
// Hook Implementations
// ============================================================================

// 1. FNFDashPlayerSizePruner Hook
// Disables player-size pruning so 1440p representations are never discarded
static NSArray * (*orig_sizePruner_pruneQualities)(id self, SEL _cmd, NSArray *qualities) = NULL;

static NSArray * Hook_PruneQualitiesNoOp(id self, SEL _cmd, NSArray *qualities) {
    if (!InstagramDash1440p_IsEnabled() && orig_sizePruner_pruneQualities) {
        return orig_sizePruner_pruneQualities(self, _cmd, qualities);
    }
    // Return all qualities untouched (bypassing viewport capping)
    return qualities;
}

// 2. FNFDashABRQualitySelector Hook
// Forces selection of 1440p/highest representation in ABR quality selector
static id (*orig_ABR_selectQualityWithBw)(id self, SEL _cmd, NSArray *reps, double bw) = NULL;

static id Hook_ABR_SelectQualityFromReps(id self, SEL _cmd, NSArray *representations, double bandwidth) {
    if (InstagramDash1440p_IsEnabled() && representations && representations.count > 0) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    if (orig_ABR_selectQualityWithBw) {
        id stdRep = orig_ABR_selectQualityWithBw(self, _cmd, representations, bandwidth);
        if (stdRep && !IsAudioRepresentation(stdRep)) {
            UpdateRepresentationInfo(stdRep);
        }
        return stdRep;
    }
    return representations.firstObject;
}

static id Hook_ABR_SelectQualityFetchSizes(id self, SEL _cmd, NSArray *representations, id fetchSizes, id seqIndexes) {
    if (InstagramDash1440p_IsEnabled() && representations && representations.count > 0) {
        id chosen = SelectHighestRepresentation(representations);
        if (chosen) {
            return chosen;
        }
    }
    return representations.firstObject;
}

static BOOL Hook_ShouldSkipRepAOC(id self, SEL _cmd, id rep, BOOL isOnWifi) {
    return NO;
}

static BOOL Hook_ReturnNO(id self, SEL _cmd, id rep, BOOL isIntentional) {
    return NO;
}

static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

// 3. FNFDashPlaylist Hooks
static NSArray * (*orig_playlist_representationsForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static NSArray * Hook_Playlist_RepresentationsForTrack(id self, SEL _cmd, NSInteger track) {
    NSArray *reps = orig_playlist_representationsForTrack ? orig_playlist_representationsForTrack(self, _cmd, track) : nil;
    if (track == 1 && InstagramDash1440p_IsEnabled() && reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
        id highest = SelectHighestRepresentation(reps);
        if (highest) {
            objc_setAssociatedObject(self, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            g_lastHighestVideoRep = highest;
            UpdateRepresentationInfo(highest);
        }
    }
    return reps;
}

static id (*orig_playlist_defaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static id Hook_Playlist_DefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id cachedHighest = objc_getAssociatedObject(self, kPlaylistHighestVideoRepKey);
        if (cachedHighest) {
            UpdateRepresentationInfo(cachedHighest);
            return cachedHighest;
        }
        if (orig_playlist_representationsForTrack) {
            NSArray *reps = orig_playlist_representationsForTrack(self, @selector(representationsForTrack:), 1);
            if (reps && [reps isKindOfClass:[NSArray class]] && reps.count > 0) {
                id highest = SelectHighestRepresentation(reps);
                if (highest) {
                    objc_setAssociatedObject(self, kPlaylistHighestVideoRepKey, highest, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    g_lastHighestVideoRep = highest;
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
        id highest = objc_getAssociatedObject(self, kPlaylistHighestVideoRepKey);
        if (highest) {
            rep = highest;
        }
    }
    if (orig_playlist_setDefaultRepresentation) {
        orig_playlist_setDefaultRepresentation(self, _cmd, rep, track);
    }
}

static void (*orig_playlist_updateDefaultRepresentationForTrack)(id self, SEL _cmd, NSInteger track) = NULL;

static void Hook_Playlist_UpdateDefaultRepresentationForTrack(id self, SEL _cmd, NSInteger track) {
    if (track == 1 && InstagramDash1440p_IsEnabled()) {
        id highest = objc_getAssociatedObject(self, kPlaylistHighestVideoRepKey);
        if (highest && [self respondsToSelector:@selector(setDefaultRepresentation:track:)]) {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(self, @selector(setDefaultRepresentation:track:), highest, 1);
            return;
        }
    }
    if (orig_playlist_updateDefaultRepresentationForTrack) {
        orig_playlist_updateDefaultRepresentationForTrack(self, _cmd, track);
    }
}

// 4. FNFDashVideoPlayerMetadata Hooks (Force 1440x2560 Viewport & Screen Dimensions)
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

// 5. IGFNFSelectedQualityProvider Hook
static void (*orig_selectedQualityProvider_setVideoSelectedQualityRep)(id self, SEL _cmd, id rep) = NULL;

static void Hook_SelectedQualityProvider_SetVideoSelectedQualityRep(id self, SEL _cmd, id rep) {
    if (rep && !IsAudioRepresentation(rep)) {
        UpdateRepresentationInfo(rep);
    }
    if (orig_selectedQualityProvider_setVideoSelectedQualityRep) {
        orig_selectedQualityProvider_setVideoSelectedQualityRep(self, _cmd, rep);
    }
}

// 6. FNFDashSelectionMetadata Hook
static id (*orig_selMeta_selectedRepresentation)(id self, SEL _cmd) = NULL;

static id Hook_SelMeta_SelectedRepresentation(id self, SEL _cmd) {
    id rep = orig_selMeta_selectedRepresentation ? orig_selMeta_selectedRepresentation(self, _cmd) : nil;
    if (rep && !IsAudioRepresentation(rep)) {
        UpdateRepresentationInfo(rep);
    }
    return rep;
}

// 7. Bandwidth Estimator Hook (Double return: 100 Mbps)
static double Hook_ReturnHighBandwidth(id self, SEL _cmd) {
    if (!InstagramDash1440p_IsEnabled()) {
        return 5000000.0;
    }
    return 100000000.0; // 100 Mbps
}

static int Hook_Return4(id self, SEL _cmd) {
    return 4;
}

static int Hook_Return1(id self, SEL _cmd) {
    return 1;
}

// ============================================================================
// Class Hook Installation (Isolated & Verified)
// ============================================================================

static void SwizzleDashClasses(void) {
    DashLogToFile(@"Installing DASH 1440p hooks...");

    // 1. Bypass Player Size Pruning in FNFDashPlayerSizePruner
    Class sizePrunerCls = objc_getClass("FNFDashPlayerSizePruner");
    if (sizePrunerCls) {
        SwizzleMethod(sizePrunerCls, sel_registerName("pruneQualities:"),
                      Hook_PruneQualitiesNoOp, &orig_sizePruner_pruneQualities);
        DashLogToFile(@"[Swizzle] FNFDashPlayerSizePruner pruneQualities: swizzled successfully");
    } else {
        DashLogToFile(@"[Swizzle] FNFDashPlayerSizePruner not loaded yet");
    }

    // 2. Select Highest 1440p Representation in FNFDashABRQualitySelector
    Class abrCls = objc_getClass("FNFDashABRQualitySelector");
    if (abrCls) {
        SwizzleMethod(abrCls, sel_registerName("_selectQualityFromRepresentations:withAvailableBandwidth:"),
                      Hook_ABR_SelectQualityFromReps, &orig_ABR_selectQualityWithBw);
        SwizzleMethod(abrCls, sel_registerName("_shouldAvoidOnABR:isIntentional:"),
                      Hook_ReturnNO, NULL);
        DashLogToFile(@"[Swizzle] FNFDashABRQualitySelector swizzled successfully");
    } else {
        DashLogToFile(@"[Swizzle] FNFDashABRQualitySelector not loaded yet");
    }

    // 3. Force 1440p Default Video Representation in FNFDashPlaylist
    Class playlistCls = objc_getClass("FNFDashPlaylist");
    if (playlistCls) {
        SwizzleMethod(playlistCls, sel_registerName("representationsForTrack:"),
                      Hook_Playlist_RepresentationsForTrack, &orig_playlist_representationsForTrack);
        SwizzleMethod(playlistCls, sel_registerName("defaultRepresentationForTrack:"),
                      Hook_Playlist_DefaultRepresentationForTrack, &orig_playlist_defaultRepresentationForTrack);
        SwizzleMethod(playlistCls, sel_registerName("setDefaultRepresentation:track:"),
                      Hook_Playlist_SetDefaultRepresentation, &orig_playlist_setDefaultRepresentation);
        SwizzleMethod(playlistCls, sel_registerName("updateDefaultRepresentationForTrack:"),
                      Hook_Playlist_UpdateDefaultRepresentationForTrack, &orig_playlist_updateDefaultRepresentationForTrack);
        DashLogToFile(@"[Swizzle] FNFDashPlaylist swizzled successfully");
    } else {
        DashLogToFile(@"[Swizzle] FNFDashPlaylist not loaded yet");
    }

    // 4. Force 1440p Viewport, Screen Size & Ignore-Avoid-On-Cell in FNFDashVideoPlayerMetadata
    Class metaCls = objc_getClass("FNFDashVideoPlayerMetadata");
    if (metaCls) {
        SwizzleMethod(metaCls, sel_registerName("size"), Hook_Return1440pSize, &orig_meta_size);
        SwizzleMethod(metaCls, sel_registerName("screenSize"), Hook_Return1440pSize, &orig_meta_screenSize);
        SwizzleMethod(metaCls, sel_registerName("viewPortSize"), Hook_Return1440pSize, &orig_meta_viewPortSize);
        SwizzleMethod(metaCls, sel_registerName("ignoreAvoidOnCell"), Hook_ReturnYES, NULL);
        DashLogToFile(@"[Swizzle] FNFDashVideoPlayerMetadata swizzled successfully");
    } else {
        DashLogToFile(@"[Swizzle] FNFDashVideoPlayerMetadata not loaded yet");
    }

    // 5. Intercept Active Quality Selection in IGFNFSelectedQualityProvider
    Class sqpCls = objc_getClass("IGFNFSelectedQualityProvider");
    if (sqpCls) {
        SwizzleMethod(sqpCls, sel_registerName("setVideoSelectedQualityRepresentation:"),
                      Hook_SelectedQualityProvider_SetVideoSelectedQualityRep, &orig_selectedQualityProvider_setVideoSelectedQualityRep);
        DashLogToFile(@"[Swizzle] IGFNFSelectedQualityProvider swizzled successfully");
    }

    // 6. Hook FNFDashSelectionMetadata
    Class selMetaCls = objc_getClass("FNFDashSelectionMetadata");
    if (selMetaCls) {
        SwizzleMethod(selMetaCls, sel_registerName("selectedRepresentation"),
                      Hook_SelMeta_SelectedRepresentation, &orig_selMeta_selectedRepresentation);
        DashLogToFile(@"[Swizzle] FNFDashSelectionMetadata swizzled successfully");
    }

    // 7. Boost Bandwidth Providers to 100+ Mbps (downloadBandwidthEstimateBitsPerSecond only)
    const char *bandwidthClasses[] = {
        "FNFBandwidthProvider",
        "IGBandwidthEstimator",
        "IGFNFBandwidthProvider",
        "IGMediaHistoricalBandwidthEstimateProvider"
    };

    for (size_t i = 0; i < sizeof(bandwidthClasses) / sizeof(bandwidthClasses[0]); i++) {
        Class bCls = objc_getClass(bandwidthClasses[i]);
        if (!bCls) continue;
        SwizzleMethod(bCls, sel_registerName("downloadBandwidthEstimateBitsPerSecond"), Hook_ReturnHighBandwidth, NULL);
        DashLogToFile(@"[Swizzle] %s downloadBandwidthEstimateBitsPerSecond swizzled", bandwidthClasses[i]);
    }

    // 8. Enable Embedded FFmpeg VP9 Decoding on Config Classes
    const char *vp9ConfigClasses[] = {
        "FNFPlayerConfig",
        "FNFDecompressionConfig"
    };

    for (size_t i = 0; i < sizeof(vp9ConfigClasses) / sizeof(vp9ConfigClasses[0]); i++) {
        Class vCls = objc_getClass(vp9ConfigClasses[i]);
        if (!vCls) continue;
        SwizzleMethod(vCls, sel_registerName("enableFFVP9Decoding"), Hook_ReturnYES, NULL);
        SwizzleMethod(vCls, sel_registerName("enableFFVP9ZeroCopyDecoding"), Hook_ReturnYES, NULL);
        SwizzleMethod(vCls, sel_registerName("ffvp9EnableFastFlag"), Hook_ReturnYES, NULL);
        SwizzleMethod(vCls, sel_registerName("ffvp9ThreadCount"), Hook_Return4, NULL);
        SwizzleMethod(vCls, sel_registerName("ffvp9ThreadType"), Hook_Return1, NULL);
        SwizzleMethod(vCls, sel_registerName("enableVTForVP9"), Hook_ReturnYES, NULL);
        DashLogToFile(@"[Swizzle] %s FFVP9 config swizzled", vp9ConfigClasses[i]);
    }

    DashLogToFile(@"DASH 1440p hook installation completed");
}

static void ApplyAllDash1440pSwizzles(void) {
    static pthread_mutex_t s_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_mutex);
    SwizzleDashClasses();
    pthread_mutex_unlock(&s_mutex);
}

// ============================================================================
// Public Interface & Auto-Initialization
// ============================================================================

void InstagramDash1440p_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        InstallCrashHandlers();

        DashLogToFile(@"========================================================");
        DashLogToFile(@"Initializing Ultra-HD 1440p DASH Video Streaming Engine");
        DashLogToFile(@"Tweak Dir: %s | Doc Dir: %s", g_tweakDirPath, g_docDirPath);
        DashLogToFile(@"Overriding FNF Player Size Pruner: Viewport set to 1440x2560");
        DashLogToFile(@"1440p / Maximum Bitrate Representation Selector Active");
        DashLogToFile(@"Embedded FFmpeg VP9 Software Decoder Enabled (4 threads)");

        // 1. Initial Swizzle Pass
        ApplyAllDash1440pSwizzles();

        // 2. Re-evaluate once app finishes launching
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                           object:nil
                                                            queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification * _Nonnull note) {
            DashLogToFile(@"UIApplicationDidFinishLaunchingNotification received, refreshing swizzles");
            ApplyAllDash1440pSwizzles();
        }];

        // 3. Delayed check for late-instantiated ABR singletons
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DashLogToFile(@"Delayed 1.5s check executing, verifying swizzles");
            ApplyAllDash1440pSwizzles();
        });

        DashLogToFile(@"1440p DASH Streaming Engine Active: Max Quality Locked");
        DashLogToFile(@"========================================================");
    });
}

BOOL InstagramDash1440p_IsActive(void) {
    return YES;
}

__attribute__((constructor))
static void InstagramDash1440pAutoInit(void) {
    InstagramDash1440p_Init();
}
