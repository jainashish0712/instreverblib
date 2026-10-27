// InstagramWifiSpoofer.m
// Automatic Cellular-to-Wi-Fi Spoofing Engine for Instagram
//
// Purpose:
// Fakes cellular data connection as an active, unmetered, high-bandwidth Wi-Fi network
// so Instagram's Adaptive Bitrate (ABR) player (Sundial/FNF) unconditionally streams Reels
// and videos in full 1080p high quality without downscaling to 720p/480p on cellular data.
//
// Safety:
// Low-level POSIX and Network.framework kernel socket routing (getifaddrs, nw_path_uses_interface_type)
// are strictly preserved untouched so cellular IP packets route uninterrupted through the iOS kernel.
//
// 100% Automatic: Zero UI, zero toggles, permanently active in background.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import "fishhook.h"
#import "InstagramWifiSpoofer.h"

// ============================================================================
// Tier 1: Objective-C Return Stubs (High-Level Wi-Fi & Bandwidth Emulation)
// ============================================================================

// Returns BOOL YES
static BOOL Hook_ReturnYES(id self, SEL _cmd) {
    return YES;
}

// Returns BOOL NO
static BOOL Hook_ReturnNO(id self, SEL _cmd) {
    return NO;
}

// Returns NSString* @"wifi"
static NSString *Hook_ReturnWifiString(id self, SEL _cmd) {
    return @"wifi";
}

// Returns NSString* @"WIFI"
static NSString *Hook_ReturnWIFILargeString(id self, SEL _cmd) {
    return @"WIFI";
}

// Returns NSInteger 2 (ReachableViaWiFi / Wi-Fi Reachability State)
static NSInteger Hook_ReturnReachabilityWiFi(id self, SEL _cmd) {
    return 2;
}

// Returns NSString* standard Wi-Fi BSSID placeholder
static NSString *Hook_ReturnBSSID(id self, SEL _cmd) {
    return @"02:00:00:00:00:00";
}

// Returns NSInteger 3 (Bandwidth State: Excellent / High-Speed)
static NSInteger Hook_ReturnBandwidthStateHigh(id self, SEL _cmd) {
    return 3;
}

// Returns double 50000.0 (50 MB/s = 400 Mbps Wi-Fi bandwidth)
static double Hook_ReturnBandwidthHighDouble(id self, SEL _cmd) {
    return 50000.0;
}

// Returns uint64_t 400000000 (400 Mbps in bits/sec)
static uint64_t Hook_ReturnBandwidthHighBits(id self, SEL _cmd) {
    return 400000000ULL;
}

// Returns uint64_t 50000 (50,000 KB/s)
static uint64_t Hook_ReturnBandwidthHighKbps(id self, SEL _cmd) {
    return 50000ULL;
}

// ============================================================================
// Objective-C Runtime Swizzling Helpers
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
// Swizzling Implementations per Target Class
// ============================================================================

static void SwizzleIGNetworkInfo(void) {
    Class cls = objc_getClass("IGNetworkInfo");
    if (!cls) return;

    SwizzleBoth(cls, sel_registerName("isOnWifiNetwork"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isOnWifi"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isReachableViaWiFi"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isReachableViaWWAN"), (IMP)Hook_ReturnNO, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isReachable"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("connectionTypeString"), (IMP)Hook_ReturnWifiString, NULL, "@@:");
    SwizzleBoth(cls, sel_registerName("fbConnectionTypeString"), (IMP)Hook_ReturnWIFILargeString, NULL, "@@:");
    SwizzleBoth(cls, sel_registerName("networkTypeString"), (IMP)Hook_ReturnWifiString, NULL, "@@:");
    SwizzleBoth(cls, sel_registerName("networkReachabilityStatus"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("networkReachability"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("radioType"), (IMP)Hook_ReturnWIFILargeString, NULL, "@@:");
}

static void SwizzleFBReachabilityAnnouncer(void) {
    Class cls = objc_getClass("FBReachabilityAnnouncer");
    if (!cls) return;

    SwizzleBoth(cls, sel_registerName("currentReachabilityState"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("reachabilityState"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("networkBSSID"), (IMP)Hook_ReturnBSSID, NULL, "@@:");
    SwizzleBoth(cls, sel_registerName("currentDownloadBandwidthState"), (IMP)Hook_ReturnBandwidthStateHigh, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("currentDownloadBandwidthEstimate"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
    SwizzleBoth(cls, sel_registerName("currentUploadBandwidthState"), (IMP)Hook_ReturnBandwidthStateHigh, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("currentUploadBandwidthEstimate"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
    SwizzleBoth(cls, sel_registerName("isConnectionConstrained"), (IMP)Hook_ReturnNO, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isConnectionExpensive"), (IMP)Hook_ReturnNO, NULL, "B@:");
}

static void SwizzleMETANetworkReachabilityMonitor(void) {
    Class cls = objc_getClass("METANetworkReachabilityMonitor");
    if (!cls) return;

    SwizzleBoth(cls, sel_registerName("currentReachabilityState"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("reachabilityState"), (IMP)Hook_ReturnReachabilityWiFi, NULL, "q@:");
    SwizzleBoth(cls, sel_registerName("isReachable"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isOnWifi"), (IMP)Hook_ReturnYES, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isConnectionConstrained"), (IMP)Hook_ReturnNO, NULL, "B@:");
    SwizzleBoth(cls, sel_registerName("isConnectionExpensive"), (IMP)Hook_ReturnNO, NULL, "B@:");
}

static void SwizzleBandwidthEstimators(void) {
    const char *classNames[] = {
        "FNFBandwidthEstimator",
        "IGFNFBandwidthProvider",
        "IGMediaBandwidthEstimator",
        "IGMediaExponentialMovingAverageBandwidthEstimator",
        "IGNetworkingBandwidthRecorder",
        "IGNetworkSpeedManager"
    };

    for (size_t i = 0; i < sizeof(classNames) / sizeof(classNames[0]); i++) {
        Class cls = objc_getClass(classNames[i]);
        if (!cls) continue;

        SwizzleBoth(cls, sel_registerName("estimatedBandwidthInKilobytesPerSecond"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
        SwizzleBoth(cls, sel_registerName("aiq_estimatedBandwidthInKilobytesPerSecond"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
        SwizzleBoth(cls, sel_registerName("bandwidthEstimate"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
        SwizzleBoth(cls, sel_registerName("estimatedBandwidth"), (IMP)Hook_ReturnBandwidthHighDouble, NULL, "d@:");
        SwizzleBoth(cls, sel_registerName("downloadBandwidthEstimateBitsPerSecond"), (IMP)Hook_ReturnBandwidthHighBits, NULL, "Q@:");
        SwizzleBoth(cls, sel_registerName("downloadBandwidthEstimateKbps"), (IMP)Hook_ReturnBandwidthHighKbps, NULL, "Q@:");
        SwizzleBoth(cls, sel_registerName("downloadBandwidthKbps"), (IMP)Hook_ReturnBandwidthHighKbps, NULL, "Q@:");
        SwizzleBoth(cls, sel_registerName("currentBandwidthQuality"), (IMP)Hook_ReturnBandwidthStateHigh, NULL, "q@:");
        SwizzleBoth(cls, sel_registerName("networkSpeed"), (IMP)Hook_ReturnBandwidthStateHigh, NULL, "q@:");
    }
}

static void ApplyAllObjCSwizzles(void) {
    static pthread_mutex_t s_swizzleMutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&s_swizzleMutex);

    SwizzleIGNetworkInfo();
    SwizzleFBReachabilityAnnouncer();
    SwizzleMETANetworkReachabilityMonitor();
    SwizzleBandwidthEstimators();

    pthread_mutex_unlock(&s_swizzleMutex);
}

// Callback invoked by dyld whenever any Mach-O image is mapped
static void ImageLoadedCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    ApplyAllObjCSwizzles();
}

// ============================================================================
// Tier 2: SystemConfiguration Advisory Reachability C Hook
// ============================================================================

static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) = NULL;

static Boolean My_SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) {
    Boolean res = true;
    if (orig_SCNetworkReachabilityGetFlags) {
        res = orig_SCNetworkReachabilityGetFlags(target, flags);
    }
    if (flags) {
        // 1. Strip WWAN cellular bit: 1 << 18 (0x40000)
        *flags &= ~((SCNetworkReachabilityFlags)kSCNetworkReachabilityFlagsIsWWAN);
        // 2. Strip ConnectionRequired (1 << 2) & InterventionRequired (1 << 4)
        *flags &= ~((SCNetworkReachabilityFlags)(kSCNetworkReachabilityFlagsConnectionRequired | kSCNetworkReachabilityFlagsInterventionRequired));
        // 3. Strip ConnectionOnDemand (1 << 5) & ConnectionOnTraffic (1 << 3)
        *flags &= ~((SCNetworkReachabilityFlags)(kSCNetworkReachabilityFlagsConnectionOnDemand | kSCNetworkReachabilityFlagsConnectionOnTraffic));
        // 4. Force Reachable (1 << 1)
        *flags |= (SCNetworkReachabilityFlags)kSCNetworkReachabilityFlagsReachable;
    }
    return res;
}

// ============================================================================
// Tier 3: Network.framework Advisory Path Property C Hooks
// (Never overrides socket interfaces or routing types)
// ============================================================================

static bool (*orig_nw_path_is_expensive)(void *path) = NULL;
static bool (*orig_nw_path_is_constrained)(void *path) = NULL;
static bool (*orig_nw_path_is_ultra_constrained)(void *path) = NULL;

static bool My_nw_path_is_expensive(void *path) {
    // Wi-Fi connection is unmetered and never expensive
    return false;
}

static bool My_nw_path_is_constrained(void *path) {
    // Low Data Mode is never active
    return false;
}

static bool My_nw_path_is_ultra_constrained(void *path) {
    return false;
}

// ============================================================================
// C Function Interception Installation
// ============================================================================

static void InstallCFunctionHooks(void) {
    // 1. Resolve real pointers directly from system frameworks
    void *scHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW | RTLD_GLOBAL);
    if (scHandle) {
        orig_SCNetworkReachabilityGetFlags = (Boolean (*)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *))dlsym(scHandle, "SCNetworkReachabilityGetFlags");
    }
    if (!orig_SCNetworkReachabilityGetFlags) {
        orig_SCNetworkReachabilityGetFlags = (Boolean (*)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *))dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags");
    }

    void *nwHandle = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_NOW | RTLD_GLOBAL);
    if (nwHandle) {
        orig_nw_path_is_expensive = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_expensive");
        orig_nw_path_is_constrained = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_constrained");
        orig_nw_path_is_ultra_constrained = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_ultra_constrained");
    }
    if (!orig_nw_path_is_expensive) {
        orig_nw_path_is_expensive = (bool (*)(void *))dlsym(RTLD_DEFAULT, "nw_path_is_expensive");
    }
    if (!orig_nw_path_is_constrained) {
        orig_nw_path_is_constrained = (bool (*)(void *))dlsym(RTLD_DEFAULT, "nw_path_is_constrained");
    }
    if (!orig_nw_path_is_ultra_constrained) {
        orig_nw_path_is_ultra_constrained = (bool (*)(void *))dlsym(RTLD_DEFAULT, "nw_path_is_ultra_constrained");
    }

    // 2. Safe Dynamic Symbol Rebinding via fishhook
    struct rebinding rebs[] = {
        {"SCNetworkReachabilityGetFlags", (void *)My_SCNetworkReachabilityGetFlags, (void **)&orig_SCNetworkReachabilityGetFlags},
        {"nw_path_is_expensive", (void *)My_nw_path_is_expensive, (void **)&orig_nw_path_is_expensive},
        {"nw_path_is_constrained", (void *)My_nw_path_is_constrained, (void **)&orig_nw_path_is_constrained},
        {"nw_path_is_ultra_constrained", (void *)My_nw_path_is_ultra_constrained, (void **)&orig_nw_path_is_ultra_constrained}
    };
    rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
}

// ============================================================================
// Public Interface & Auto-Initialization
// ============================================================================

void InstagramWifiSpoofer_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[InstagramWifiSpoofer] ========================================================");
        NSLog(@"[InstagramWifiSpoofer] Initializing Automatic Cellular-to-Wi-Fi Spoofing Engine");
        NSLog(@"[InstagramWifiSpoofer] Target: Force 1080p ABR Streaming for Reels and Videos");

        // Tier 2 & Tier 3: Install advisory reachability C function hooks
        InstallCFunctionHooks();

        // Tier 1: Objective-C Runtime Swizzles
        ApplyAllObjCSwizzles();

        // Monitor future loaded Mach-O images
        _dyld_register_func_for_add_image(ImageLoadedCallback);

        // Re-apply once app finishes launching to guarantee coverage of late singletons
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            ApplyAllObjCSwizzles();
            InstallCFunctionHooks();
        }];

        // Delayed check for lazy ABR singletons
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApplyAllObjCSwizzles();
        });

        NSLog(@"[InstagramWifiSpoofer] Wi-Fi Spoofing Engine Active: Cellular -> Wi-Fi Locked");
        NSLog(@"[InstagramWifiSpoofer] ========================================================");
    });
}

BOOL InstagramWifiSpoofer_IsActive(void) {
    return YES;
}

__attribute__((constructor))
static void InstagramWifiSpooferAutoInit(void) {
    InstagramWifiSpoofer_Init();
}
