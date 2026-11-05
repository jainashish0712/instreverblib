// InstagramDash1440pUI.m
// Floating Draggable 1440p DASH Quality & Telemetry HUD Overlay for Instagram
// Features: Active 1440p/1080p stream resolution pill & real-time hardware telemetry badge

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <mach/thread_act.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <dlfcn.h>
#import "InstagramDash1440pUI.h"
#import "InstagramDash1440p.h"
#import "InstagramWifiSpoofer.h"

// ============================================================================
// Passthrough Overlay Window (Always Floats Above Reels, Stories & Modals)
// ============================================================================
@interface InstagramDash1440pOverlayWindow : UIWindow
@end

@implementation InstagramDash1440pOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView || hitView == self || hitView == self.rootViewController.view) {
        return nil; // Pass touches through to Instagram
    }
    return hitView;
}

@end

@interface InstagramDash1440pOverlayViewController : UIViewController
@end

@implementation InstagramDash1440pOverlayViewController

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

@end

// ============================================================================
// Floating Draggable 1440p DASH Quality Pill
// ============================================================================
@interface InstagramDash1440pPill : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *titleLabel;
- (void)updateAppearance;
@end

@implementation InstagramDash1440pPill

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:(18.0f/255.0f) green:(18.0f/255.0f) blue:(18.0f/255.0f) alpha:0.88f];
        self.layer.cornerRadius = 10.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:0.90f].CGColor;
        self.clipsToBounds = YES;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(8.0f, 7.5f, 5.0f, 5.0f)];
        _statusDot.layer.cornerRadius = 2.5f;
        _statusDot.layer.masksToBounds = YES;
        _statusDot.userInteractionEnabled = NO;
        [self addSubview:_statusDot];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(17.0f, 0.0f, frame.size.width - 23.0f, 20.0f)];
        _titleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentLeft;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onDashStateChanged:)
                                                     name:kInstagramDash1440pStateDidChangeNotification
                                                   object:nil];
        [self updateAppearance];
    }
    return self;
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    InstagramDash1440p_CycleMode();
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self updateAppearance];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = self.bounds.size.width / 2.0f;
    CGFloat halfH = self.bounds.size.height / 2.0f;
    newCenter.x = MAX(halfW + 6.0f, MIN(superview.bounds.size.width - halfW - 6.0f, newCenter.x));
    newCenter.y = MAX(halfH + 30.0f, MIN(superview.bounds.size.height - halfH - 30.0f, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:superview];
}

- (void)onDashStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAppearance];
    });
}

- (void)updateAppearance {
    InstagramDash1440pMode mode = InstagramDash1440p_GetMode();
    NSString *quality = InstagramDash1440p_GetCurrentQuality() ?: @"1440p";
    NSString *repId = InstagramDash1440p_GetCurrentRepresentationId() ?: @"ready";

    NSString *text = nil;
    if (mode == InstagramDash1440pModeDisabled) {
        text = [NSString stringWithFormat:@"OFF (IG Default): %@", repId];
        self.layer.borderColor = [UIColor colorWithWhite:0.6f alpha:0.45f].CGColor;
        self.statusDot.backgroundColor = [UIColor colorWithWhite:0.6f alpha:0.8f];
        self.titleLabel.textColor = [UIColor colorWithWhite:0.75f alpha:1.0f];
    } else if (mode == InstagramDash1440pModeWifiOnly) {
        BOOL isCell = InstagramWifiSpoofer_IsCellularData();
        if (isCell) {
            text = [NSString stringWithFormat:@"WiFi-1440p [Cell 1080p]: %@", repId];
            self.layer.borderColor = [UIColor colorWithRed:(29.0f/255.0f) green:(185.0f/255.0f) blue:(84.0f/255.0f) alpha:0.85f].CGColor;
            self.statusDot.backgroundColor = [UIColor colorWithRed:(29.0f/255.0f) green:(185.0f/255.0f) blue:(84.0f/255.0f) alpha:1.0f];
        } else {
            text = [NSString stringWithFormat:@"WiFi-1440p [%@]: %@", quality, repId];
            self.layer.borderColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:0.90f].CGColor;
            self.statusDot.backgroundColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:1.0f];
        }
        self.titleLabel.textColor = [UIColor whiteColor];
    } else { // InstagramDash1440pModeAlways1440p
        text = [NSString stringWithFormat:@"All-1440p [%@]: %@", quality, repId];
        self.layer.borderColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:0.95f].CGColor;
        self.statusDot.backgroundColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:1.0f];
        self.titleLabel.textColor = [UIColor whiteColor];
    }
    self.titleLabel.text = text;

    CGSize fit = [self.titleLabel sizeThatFits:CGSizeMake(360.0f, 20.0f)];
    CGFloat targetWidth = MAX(130.0f, MIN(360.0f, fit.width + 26.0f));

    CGRect f = self.frame;
    f.size.width = targetWidth;
    f.size.height = 20.0f;
    self.frame = f;
    self.titleLabel.frame = CGRectMake(17.0f, 0.0f, targetWidth - 23.0f, 20.0f);
}

@end

// ============================================================================
// Real-Time System & Hardware Performance Telemetry Badge (2-Second Polling)
// ============================================================================

typedef struct {
    uint64_t wifiInBytes;
    uint64_t wifiOutBytes;
    uint64_t cellInBytes;
    uint64_t cellOutBytes;
} PerfNetStats;

@interface InstagramPerfHUDPill : UIView
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) NSInteger displayMode;
@property (nonatomic, assign) PerfNetStats lastNetStats;
@property (nonatomic, assign) NSTimeInterval lastPollTimestamp;
@property (nonatomic, assign) BOOL isDimmed;
- (void)startPolling;
- (void)stopPolling;
- (void)refreshMetrics;
@end

@implementation InstagramPerfHUDPill

static float QueryCurrentProcessCPU(void) {
    kern_return_t kr;
    thread_array_t threadList;
    mach_msg_type_number_t threadCount = 0;

    kr = task_threads(mach_task_self(), &threadList, &threadCount);
    if (kr != KERN_SUCCESS) {
        return 0.0f;
    }

    float totalCpu = 0.0f;
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        thread_info_data_t thInfo;
        mach_msg_type_number_t infoCount = THREAD_INFO_MAX;
        kr = thread_info(threadList[i], THREAD_BASIC_INFO, (thread_info_t)thInfo, &infoCount);
        if (kr == KERN_SUCCESS) {
            thread_basic_info_t basicInfo = (thread_basic_info_t)thInfo;
            if (!(basicInfo->flags & TH_FLAGS_IDLE)) {
                totalCpu += (basicInfo->cpu_usage / (float)TH_USAGE_SCALE) * 100.0f;
            }
        }
    }

    vm_deallocate(mach_task_self(), (vm_address_t)threadList, threadCount * sizeof(thread_t));
    return totalCpu;
}

static float ExtractGPUValueFromDict(CFDictionaryRef dict) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return -1.0f;
    const CFStringRef keys[] = {
        CFSTR("Device Utilization %"),
        CFSTR("GPU Core Utilization"),
        CFSTR("Renderer Utilization %"),
        CFSTR("Tiler Utilization %"),
        CFSTR("Device Utilization"),
        CFSTR("gpu-core-utilization"),
        CFSTR("device-utilization")
    };
    for (size_t k = 0; k < sizeof(keys)/sizeof(keys[0]); k++) {
        CFTypeRef num = CFDictionaryGetValue(dict, keys[k]);
        if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
            float val = 0.0f;
            if (CFNumberGetValue((CFNumberRef)num, kCFNumberFloatType, &val)) {
                if (val >= 0.0f) {
                    return val;
                }
            }
        }
    }
    return -1.0f;
}

static float QueryCurrentGPU(void) {
    static void *s_iokit = NULL;
    static dispatch_once_t s_once;
    typedef void* io_service_t;
    typedef void* io_iterator_t;
    typedef void* io_registry_entry_t;
    typedef CFMutableDictionaryRef (*IOServiceMatchingFunc)(const char *name);
    typedef kern_return_t (*IOServiceGetMatchingServicesFunc)(mach_port_t mainPort, CFDictionaryRef matching, io_iterator_t *existing);
    typedef io_registry_entry_t (*IOIteratorNextFunc)(io_iterator_t iterator);
    typedef kern_return_t (*IORegistryEntryCreateCFPropertiesFunc)(io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
    typedef kern_return_t (*IOObjectReleaseFunc)(void *object);

    static IOServiceMatchingFunc s_IOServiceMatching = NULL;
    static IOServiceGetMatchingServicesFunc s_IOServiceGetMatchingServices = NULL;
    static IOIteratorNextFunc s_IOIteratorNext = NULL;
    static IORegistryEntryCreateCFPropertiesFunc s_IORegistryEntryCreateCFProperties = NULL;
    static IOObjectReleaseFunc s_IOObjectRelease = NULL;

    dispatch_once(&s_once, ^{
        s_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        void *handle = s_iokit ? s_iokit : RTLD_DEFAULT;
        s_IOServiceMatching = (IOServiceMatchingFunc)dlsym(handle, "IOServiceMatching");
        s_IOServiceGetMatchingServices = (IOServiceGetMatchingServicesFunc)dlsym(handle, "IOServiceGetMatchingServices");
        s_IOIteratorNext = (IOIteratorNextFunc)dlsym(handle, "IOIteratorNext");
        s_IORegistryEntryCreateCFProperties = (IORegistryEntryCreateCFPropertiesFunc)dlsym(handle, "IORegistryEntryCreateCFProperties");
        s_IOObjectRelease = (IOObjectReleaseFunc)dlsym(handle, "IOObjectRelease");
    });

    if (!s_IOServiceMatching || !s_IOServiceGetMatchingServices || !s_IOIteratorNext || !s_IORegistryEntryCreateCFProperties || !s_IOObjectRelease) {
        return -1.0f;
    }

    const char *serviceNames[] = {
        "AGXAccelerator",
        "IOGPU",
        "IOAccelerator",
        "AppleARMGPU",
        "IOAcceleratorES"
    };

    float gpuUsage = -1.0f;
    for (size_t s = 0; s < sizeof(serviceNames)/sizeof(serviceNames[0]); s++) {
        CFMutableDictionaryRef matchDict = s_IOServiceMatching(serviceNames[s]);
        if (!matchDict) continue;

        io_iterator_t iterator = 0;
        kern_return_t kr = s_IOServiceGetMatchingServices(0, matchDict, &iterator);
        if (kr != KERN_SUCCESS || !iterator) continue;

        io_registry_entry_t entry = 0;
        while ((entry = s_IOIteratorNext(iterator)) != 0) {
            CFMutableDictionaryRef props = NULL;
            if (s_IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFDictionaryRef perfStats = (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
                float val = ExtractGPUValueFromDict(perfStats);
                if (val < 0.0f) {
                    val = ExtractGPUValueFromDict(props);
                }
                CFRelease(props);

                if (val >= 0.0f) {
                    gpuUsage = val;
                    s_IOObjectRelease(entry);
                    break;
                }
            }
            s_IOObjectRelease(entry);
        }
        s_IOObjectRelease(iterator);
        if (gpuUsage >= 0.0f) break;
    }

    return gpuUsage;
}

static PerfNetStats QueryCurrentNetStats(void) {
    PerfNetStats stats = {0, 0, 0, 0};
    struct ifaddrs *interfaces = NULL;
    if ((InstagramWifiSpoofer_GetRawIfAddrs ? InstagramWifiSpoofer_GetRawIfAddrs(&interfaces) : getifaddrs(&interfaces)) == 0 && interfaces) {
        struct ifaddrs *ifa = interfaces;
        while (ifa) {
            if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK) {
                struct if_data *ifData = (struct if_data *)ifa->ifa_data;
                if (ifData) {
                    const char *name = ifa->ifa_name;
                    if (strncmp(name, "en", 2) == 0) {
                        stats.wifiInBytes += ifData->ifi_ibytes;
                        stats.wifiOutBytes += ifData->ifi_obytes;
                    } else if (strncmp(name, "pdp_ip", 6) == 0) {
                        stats.cellInBytes += ifData->ifi_ibytes;
                        stats.cellOutBytes += ifData->ifi_obytes;
                    }
                }
            }
            ifa = ifa->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return stats;
}

static NSString *FormatDataRate(double bytesPerSec) {
    if (bytesPerSec >= 1024.0 * 1024.0) {
        return [NSString stringWithFormat:@"%.1fM/s", bytesPerSec / (1024.0 * 1024.0)];
    } else if (bytesPerSec >= 1024.0) {
        return [NSString stringWithFormat:@"%.0fK/s", bytesPerSec / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%.0fB/s", bytesPerSec];
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _displayMode = 0;
        _isDimmed = NO;
        _lastPollTimestamp = [NSDate timeIntervalSinceReferenceDate];
        _lastNetStats = QueryCurrentNetStats();

        self.backgroundColor = [UIColor colorWithRed:(18.0f/255.0f) green:(18.0f/255.0f) blue:(18.0f/255.0f) alpha:0.88f];
        self.layer.cornerRadius = 10.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = [UIColor colorWithRed:(155.0f/255.0f) green:(130.0f/255.0f) blue:(255.0f/255.0f) alpha:0.85f].CGColor;
        self.clipsToBounds = YES;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(8.0f, 7.5f, 5.0f, 5.0f)];
        _statusDot.layer.cornerRadius = 2.5f;
        _statusDot.layer.masksToBounds = YES;
        _statusDot.backgroundColor = [UIColor colorWithRed:(170.0f/255.0f) green:(140.0f/255.0f) blue:(255.0f/255.0f) alpha:1.0f];
        _statusDot.userInteractionEnabled = NO;
        [self addSubview:_statusDot];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(17.0f, 0.0f, frame.size.width - 23.0f, 20.0f)];
        _titleLabel.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentLeft;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _titleLabel.text = @"CPU: -- | GPU: -- | Net: --";
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 1.0;
        [self addGestureRecognizer:longPress];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stopPolling)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(startPolling)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        [self startPolling];
    }
    return self;
}

- (void)startPolling {
    if (_pollTimer) return;
    _pollTimer = [NSTimer timerWithTimeInterval:2.0
                                         target:self
                                       selector:@selector(refreshMetrics)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPolling {
    if (_pollTimer) {
        [_pollTimer invalidate];
        _pollTimer = nil;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopPolling];
}

- (void)refreshMetrics {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval elapsed = now - self.lastPollTimestamp;
    if (elapsed <= 0.0) elapsed = 2.0;

    PerfNetStats prevStats = self.lastNetStats;
    NSInteger mode = self.displayMode;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        float cpu = QueryCurrentProcessCPU();
        float gpu = QueryCurrentGPU();
        PerfNetStats currentNet = QueryCurrentNetStats();

        uint64_t deltaWifi = (currentNet.wifiInBytes + currentNet.wifiOutBytes) - (prevStats.wifiInBytes + prevStats.wifiOutBytes);
        uint64_t deltaCell = (currentNet.cellInBytes + currentNet.cellOutBytes) - (prevStats.cellInBytes + prevStats.cellOutBytes);

        double wifiRate = (double)deltaWifi / elapsed;
        double cellRate = (double)deltaCell / elapsed;

        NSString *netText = nil;
        if (InstagramWifiSpoofer_IsCellularData()) {
            netText = [NSString stringWithFormat:@"Cell: %@", FormatDataRate(cellRate > 0.0 ? cellRate : (wifiRate > 0.0 ? wifiRate : 0.0))];
        } else if (cellRate > wifiRate && cellRate > 1024.0) {
            netText = [NSString stringWithFormat:@"Cell: %@", FormatDataRate(cellRate)];
        } else {
            netText = [NSString stringWithFormat:@"WiFi: %@", FormatDataRate(wifiRate)];
        }

        NSString *displayText = nil;
        if (mode == 1) {
            if (gpu >= 0.0f) {
                displayText = [NSString stringWithFormat:@"C:%.0f%% G:%.0f%% %@", cpu, gpu, FormatDataRate(MAX(wifiRate, cellRate))];
            } else {
                displayText = [NSString stringWithFormat:@"C:%.0f%% G:-- %@", cpu, FormatDataRate(MAX(wifiRate, cellRate))];
            }
        } else {
            if (gpu >= 0.0f) {
                displayText = [NSString stringWithFormat:@"CPU: %.0f%% | GPU: %.0f%% | %@", cpu, gpu, netText];
            } else {
                displayText = [NSString stringWithFormat:@"CPU: %.0f%% | GPU: -- | %@", cpu, netText];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastNetStats = currentNet;
            self.lastPollTimestamp = now;
            self.titleLabel.text = displayText;

            CGSize fit = [self.titleLabel sizeThatFits:CGSizeMake(360.0f, 20.0f)];
            CGFloat targetWidth = MAX(110.0f, MIN(360.0f, fit.width + 26.0f));

            CGRect f = self.frame;
            f.size.width = targetWidth;
            f.size.height = 20.0f;
            self.frame = f;
            self.titleLabel.frame = CGRectMake(17.0f, 0.0f, targetWidth - 23.0f, 20.0f);
        });
    });
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.isDimmed) {
        [UIView animateWithDuration:0.25 animations:^{
            self.alpha = 1.0f;
        }];
        self.isDimmed = NO;
        return;
    }
    self.displayMode = (self.displayMode == 0) ? 1 : 0;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    [self refreshMetrics];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.isDimmed = !self.isDimmed;
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        [UIView animateWithDuration:0.25 animations:^{
            self.alpha = self.isDimmed ? 0.25f : 1.0f;
        }];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = self.bounds.size.width / 2.0f;
    CGFloat halfH = self.bounds.size.height / 2.0f;
    newCenter.x = MAX(halfW + 6.0f, MIN(superview.bounds.size.width - halfW - 6.0f, newCenter.x));
    newCenter.y = MAX(halfH + 30.0f, MIN(superview.bounds.size.height - halfH - 30.0f, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:superview];
}

@end

@interface InstagramDash1440pUIManager ()
@property (nonatomic, strong) InstagramPerfHUDPill *perfPill;
@property (nonatomic, strong) InstagramDash1440pPill *dashPill;
@property (nonatomic, strong) InstagramDash1440pOverlayWindow *overlayWindow;
@end

@implementation InstagramDash1440pUIManager

+ (instancetype)sharedManager {
    static InstagramDash1440pUIManager *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[InstagramDash1440pUIManager alloc] init];
    });
    return sShared;
}

- (UIWindowScene *)findActiveWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    return nil;
}

- (void)startOverlay {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = [self findActiveWindowScene];
        CGRect screenBounds = [UIScreen mainScreen].bounds;

        if (!self.overlayWindow) {
            if (@available(iOS 13.0, *)) {
                if (scene) {
                    self.overlayWindow = [[InstagramDash1440pOverlayWindow alloc] initWithWindowScene:scene];
                } else {
                    self.overlayWindow = [[InstagramDash1440pOverlayWindow alloc] initWithFrame:screenBounds];
                }
            } else {
                self.overlayWindow = [[InstagramDash1440pOverlayWindow alloc] initWithFrame:screenBounds];
            }
            self.overlayWindow.windowLevel = UIWindowLevelNormal + 1000.0f; // Above Reels, Stories & modals
            self.overlayWindow.backgroundColor = [UIColor clearColor];
            self.overlayWindow.rootViewController = [[InstagramDash1440pOverlayViewController alloc] init];
            self.overlayWindow.hidden = NO;
        } else {
            if (@available(iOS 13.0, *)) {
                if (scene && self.overlayWindow.windowScene != scene) {
                    self.overlayWindow.windowScene = scene;
                }
            }
            self.overlayWindow.hidden = NO;
        }

        UIView *container = self.overlayWindow.rootViewController.view;
        if (!container) return;

        // Floating 1440p DASH Quality Pill in top-right
        if (!self.dashPill) {
            CGFloat pillW = 130.0f;
            CGFloat pillH = 20.0f;
            CGFloat initialX = container.bounds.size.width - pillW - 12.0f;
            CGFloat initialY = 54.0f; // Below status bar notch
            self.dashPill = [[InstagramDash1440pPill alloc] initWithFrame:CGRectMake(initialX, initialY, pillW, pillH)];
            [container addSubview:self.dashPill];
            [self.dashPill updateAppearance];
        } else if (!self.dashPill.superview) {
            [container addSubview:self.dashPill];
            [self.dashPill updateAppearance];
        }

        // Floating Performance Telemetry Pill right underneath dashPill
        if (!self.perfPill) {
            CGFloat perfW = 160.0f;
            CGFloat perfH = 20.0f;
            CGFloat initialX = container.bounds.size.width - perfW - 12.0f;
            CGFloat initialY = 78.0f; // Directly below dashPill (54.0f + 20.0f + 4.0f)
            self.perfPill = [[InstagramPerfHUDPill alloc] initWithFrame:CGRectMake(initialX, initialY, perfW, perfH)];
            [container addSubview:self.perfPill];
        } else if (!self.perfPill.superview) {
            [container addSubview:self.perfPill];
        }
    });
}

@end

// ============================================================================
// Auto-Register UI Overlay on App Launch
// ============================================================================
__attribute__((constructor))
static void InstagramDash1440pUIInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        [[InstagramDash1440pUIManager sharedManager] startOverlay];
    }];
}
