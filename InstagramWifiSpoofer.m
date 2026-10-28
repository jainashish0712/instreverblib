// InstagramWifiSpoofer.m
// Automatic Cellular-to-Wi-Fi Spoofing Engine for Instagram
//
// Purpose:
// Fakes cellular data connection as an active, unmetered, high-bandwidth Wi-Fi network
// so Instagram's Adaptive Bitrate (ABR) player (Sundial/FNF) unconditionally streams Reels
// and videos in full 1080p high quality without downscaling to 720p/480p on cellular data.
//
// 100% Automatic: Zero UI, zero toggles, permanently active in background.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <pthread.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import "fishhook.h"
#import "InstagramWifiSpoofer.h"

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

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
// Tier 2: SystemConfiguration & POSIX Layer C Hooks
// ============================================================================

static Boolean (*orig_SCNetworkReachabilityGetFlags)(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags) = NULL;
static int (*orig_getifaddrs)(struct ifaddrs **ifap) = NULL;

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
    return true;
}

static int My_getifaddrs(struct ifaddrs **ifap) {
    int res = orig_getifaddrs ? orig_getifaddrs(ifap) : -1;
    if (res == 0 && ifap && *ifap) {
        for (struct ifaddrs *ifa = *ifap; ifa != NULL; ifa = ifa->ifa_next) {
            if (ifa->ifa_name && strncmp(ifa->ifa_name, "pdp_ip", 6) == 0) {
                // Safely alias cellular "pdp_ip" interfaces to Wi-Fi "en0" in-place
                strncpy(ifa->ifa_name, "en0", 4);
            }
        }
    }
    return res;
}

// ============================================================================
// Tier 3: Network.framework Modern Apple Transport Layer C Hooks
// ============================================================================

static int (*orig_nw_interface_get_type)(void *interface) = NULL;
static bool (*orig_nw_path_uses_interface_type)(void *path, int type) = NULL;
static bool (*orig_nw_path_is_expensive)(void *path) = NULL;
static bool (*orig_nw_path_is_constrained)(void *path) = NULL;
static bool (*orig_nw_path_is_ultra_constrained)(void *path) = NULL;
static int (*orig_nw_path_get_status)(void *path) = NULL;

static int My_nw_interface_get_type(void *interface) {
    if (orig_nw_interface_get_type) {
        int t = orig_nw_interface_get_type(interface);
        // 2 = nw_interface_type_cellular -> remap to 1 = nw_interface_type_wifi
        if (t == 2) {
            return 1;
        }
        return t;
    }
    return 1;
}

static bool My_nw_path_uses_interface_type(void *path, int type) {
    // 1 = nw_interface_type_wifi
    if (type == 1) {
        return true;
    }
    // 2 = nw_interface_type_cellular
    if (type == 2) {
        return false;
    }
    if (orig_nw_path_uses_interface_type) {
        return orig_nw_path_uses_interface_type(path, type);
    }
    return false;
}

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

static int My_nw_path_get_status(void *path) {
    // 1 = nw_path_status_satisfied
    return 1;
}

// ============================================================================
// Targeted GOT Scanner for Chained Fixup Pointers
// Explicitly ignores InstagramReverb & InstagramWifiSpoofer to prevent recursion
// ============================================================================

static void PatchWifiGOTPointersInAllImages(void *target_func, void *replacement_func, const char *symbol_name) {
    if (!target_func || !replacement_func) return;

    uintptr_t target_addr = (uintptr_t)target_func & 0x0000007fffffffffULL;
    uintptr_t repl_addr = (uintptr_t)replacement_func;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const char *image_name = _dyld_get_image_name(i);
        if (!header || !image_name) continue;

        // 1. NEVER patch our own dylibs (prevents recursive self-interception)
        if (strstr(image_name, "InstagramReverb") || strstr(image_name, "InstagramWifiSpoofer")) {
            continue;
        }

        // 2. Only target FBSharedFramework, main Instagram executable, and CFNetwork
        if (!strstr(image_name, "FBSharedFramework") &&
            !strstr(image_name, "Instagram.app/Instagram") &&
            !strstr(image_name, "CFNetwork")) {
            continue;
        }

        uintptr_t cur = (uintptr_t)header;
        #ifdef __LP64__
        cur += sizeof(struct mach_header_64);
        #else
        cur += sizeof(struct mach_header);
        #endif

        for (uint32_t c = 0; c < header->ncmds; c++) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cur;
            if (seg->cmd == LC_SEGMENT_64) {
                const char *segname = seg->segname;
                if (strcmp(segname, "__DATA_CONST") == 0 ||
                    strcmp(segname, "__DATA") == 0 ||
                    strcmp(segname, "__AUTH_CONST") == 0) {

                    struct section_64 *sect = (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64));
                    for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                        const char *sectname = sect->sectname;
                        if (strcmp(sectname, "__got") == 0 ||
                            strcmp(sectname, "__auth_got") == 0 ||
                            strcmp(sectname, "__nl_symbol_ptr") == 0 ||
                            strcmp(sectname, "__la_symbol_ptr") == 0) {

                            uintptr_t sect_addr = (uintptr_t)slide + sect->addr;
                            size_t sect_size = (size_t)sect->size;
                            uintptr_t *slots = (uintptr_t *)sect_addr;
                            size_t num_slots = sect_size / sizeof(uintptr_t);

                            for (size_t k = 0; k < num_slots; k++) {
                                uintptr_t val = slots[k] & 0x0000007fffffffffULL;
                                if (val == target_addr) {
                                    vm_address_t page = (vm_address_t)&slots[k];
                                    kern_return_t kr = vm_protect(mach_task_self(), page, sizeof(uintptr_t), false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                                    if (kr == KERN_SUCCESS) {
                                        slots[k] = repl_addr;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cur += seg->cmdsize;
        }
    }
}

// ============================================================================
// C Function Interception Installation
// ============================================================================

static void InstallCFunctionHooks(void) {
    // 1. Resolve real pointers directly from system libraries
    void *scHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW | RTLD_GLOBAL);
    if (scHandle) {
        orig_SCNetworkReachabilityGetFlags = (Boolean (*)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *))dlsym(scHandle, "SCNetworkReachabilityGetFlags");
    }
    if (!orig_SCNetworkReachabilityGetFlags) {
        orig_SCNetworkReachabilityGetFlags = (Boolean (*)(SCNetworkReachabilityRef, SCNetworkReachabilityFlags *))dlsym(RTLD_DEFAULT, "SCNetworkReachabilityGetFlags");
    }

    orig_getifaddrs = (int (*)(struct ifaddrs **))dlsym(RTLD_DEFAULT, "getifaddrs");

    void *nwHandle = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_NOW | RTLD_GLOBAL);
    if (nwHandle) {
        orig_nw_interface_get_type = (int (*)(void *))dlsym(nwHandle, "nw_interface_get_type");
        orig_nw_path_uses_interface_type = (bool (*)(void *, int))dlsym(nwHandle, "nw_path_uses_interface_type");
        orig_nw_path_is_expensive = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_expensive");
        orig_nw_path_is_constrained = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_constrained");
        orig_nw_path_is_ultra_constrained = (bool (*)(void *))dlsym(nwHandle, "nw_path_is_ultra_constrained");
        orig_nw_path_get_status = (int (*)(void *))dlsym(nwHandle, "nw_path_get_status");
    }
    if (!orig_nw_interface_get_type) {
        orig_nw_interface_get_type = (int (*)(void *))dlsym(RTLD_DEFAULT, "nw_interface_get_type");
    }
    if (!orig_nw_path_uses_interface_type) {
        orig_nw_path_uses_interface_type = (bool (*)(void *, int))dlsym(RTLD_DEFAULT, "nw_path_uses_interface_type");
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
    if (!orig_nw_path_get_status) {
        orig_nw_path_get_status = (int (*)(void *))dlsym(RTLD_DEFAULT, "nw_path_get_status");
    }

    // 2. Global Symbol Rebinding via fishhook
    struct rebinding rebs[] = {
        {"SCNetworkReachabilityGetFlags", (void *)My_SCNetworkReachabilityGetFlags, (void **)&orig_SCNetworkReachabilityGetFlags},
        {"getifaddrs", (void *)My_getifaddrs, (void **)&orig_getifaddrs},
        {"nw_interface_get_type", (void *)My_nw_interface_get_type, (void **)&orig_nw_interface_get_type},
        {"nw_path_uses_interface_type", (void *)My_nw_path_uses_interface_type, (void **)&orig_nw_path_uses_interface_type},
        {"nw_path_is_expensive", (void *)My_nw_path_is_expensive, (void **)&orig_nw_path_is_expensive},
        {"nw_path_is_constrained", (void *)My_nw_path_is_constrained, (void **)&orig_nw_path_is_constrained},
        {"nw_path_is_ultra_constrained", (void *)My_nw_path_is_ultra_constrained, (void **)&orig_nw_path_is_ultra_constrained},
        {"nw_path_get_status", (void *)My_nw_path_get_status, (void **)&orig_nw_path_get_status}
    };
    rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));

    // 3. Direct GOT Scanner to patch any chained fixup GOT pointers
    if (orig_SCNetworkReachabilityGetFlags) {
        PatchWifiGOTPointersInAllImages((void *)orig_SCNetworkReachabilityGetFlags, (void *)My_SCNetworkReachabilityGetFlags, "SCNetworkReachabilityGetFlags");
    }
    if (orig_getifaddrs) {
        PatchWifiGOTPointersInAllImages((void *)orig_getifaddrs, (void *)My_getifaddrs, "getifaddrs");
    }
    if (orig_nw_interface_get_type) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_interface_get_type, (void *)My_nw_interface_get_type, "nw_interface_get_type");
    }
    if (orig_nw_path_uses_interface_type) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_path_uses_interface_type, (void *)My_nw_path_uses_interface_type, "nw_path_uses_interface_type");
    }
    if (orig_nw_path_is_expensive) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_path_is_expensive, (void *)My_nw_path_is_expensive, "nw_path_is_expensive");
    }
    if (orig_nw_path_is_constrained) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_path_is_constrained, (void *)My_nw_path_is_constrained, "nw_path_is_constrained");
    }
    if (orig_nw_path_is_ultra_constrained) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_path_is_ultra_constrained, (void *)My_nw_path_is_ultra_constrained, "nw_path_is_ultra_constrained");
    }
    if (orig_nw_path_get_status) {
        PatchWifiGOTPointersInAllImages((void *)orig_nw_path_get_status, (void *)My_nw_path_get_status, "nw_path_get_status");
    }
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

        // Tier 2 & Tier 3: Install C function hooks
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

int InstagramWifiSpoofer_GetRawIfAddrs(struct ifaddrs **ifap) {
    if (orig_getifaddrs) {
        return orig_getifaddrs(ifap);
    }
    return getifaddrs(ifap);
}

BOOL InstagramWifiSpoofer_IsCellularData(void) {
    // 1. Query underlying system reachability flags using the original unhooked function
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    if (target) {
        SCNetworkReachabilityFlags flags = 0;
        Boolean res = false;
        if (orig_SCNetworkReachabilityGetFlags) {
            res = orig_SCNetworkReachabilityGetFlags(target, &flags);
        } else {
            res = SCNetworkReachabilityGetFlags(target, &flags);
        }
        CFRelease(target);
        if (res && (flags & kSCNetworkReachabilityFlagsReachable)) {
            if (flags & kSCNetworkReachabilityFlagsIsWWAN) {
                return YES;
            }
            return NO;
        }
    }

    // 2. Fallback check via raw unaliased network interfaces
    struct ifaddrs *interfaces = NULL;
    int (*real_getifaddrs)(struct ifaddrs **) = orig_getifaddrs ? orig_getifaddrs : getifaddrs;
    if (real_getifaddrs && real_getifaddrs(&interfaces) == 0 && interfaces) {
        BOOL hasWifi = NO;
        BOOL hasCell = NO;
        for (struct ifaddrs *ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr && (ifa->ifa_addr->sa_family == AF_INET || ifa->ifa_addr->sa_family == AF_INET6)) {
                if (strncmp(ifa->ifa_name, "en0", 3) == 0) {
                    hasWifi = YES;
                } else if (strncmp(ifa->ifa_name, "pdp_ip", 6) == 0) {
                    hasCell = YES;
                }
            }
        }
        freeifaddrs(interfaces);
        if (hasCell && !hasWifi) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void InstagramWifiSpooferAutoInit(void) {
    InstagramWifiSpoofer_Init();
}
