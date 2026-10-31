// InstagramDash1440pUI.m
// Standalone Floating Draggable HUD & Quality Control Pill for InstagramDash1440p
// Provides on-demand 1440p VP9 DASH forcing pill with real-time CDN telemetry

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import "InstagramDash1440pUI.h"
#import "InstagramDash1440p.h"

// ============================================================================
// Passthrough Overlay Window (Floats Above Reels, Stories & Modals)
// ============================================================================
@interface InstagramDash1440pOverlayWindow : UIWindow
@end

@implementation InstagramDash1440pOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView || hitView == self || hitView == self.rootViewController.view) {
        return nil; // Pass touches through to Instagram beneath
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
    InstagramDash1440pCheckResult res = InstagramDash1440p_ForceCheckAndFetch1440p();
    if (res == InstagramDash1440pCheckResult1440pFoundAndForced) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback impactOccurred];
    } else if (res == InstagramDash1440pCheckResult1440pNotAvailable) {
        UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
        [feedback notificationOccurred:UINotificationFeedbackTypeWarning];

        // Temporarily display warning in pill
        self.titleLabel.text = @"No 1440p (Max 1080p)";
        self.layer.borderColor = [UIColor colorWithRed:1.0f green:0.65f blue:0.0f alpha:0.95f].CGColor;
        self.statusDot.backgroundColor = [UIColor colorWithRed:1.0f green:0.65f blue:0.0f alpha:1.0f];
        self.titleLabel.textColor = [UIColor colorWithRed:1.0f green:0.80f blue:0.2f alpha:1.0f];

        CGSize fit = [self.titleLabel sizeThatFits:CGSizeMake(360.0f, 20.0f)];
        CGFloat targetWidth = MAX(130.0f, MIN(360.0f, fit.width + 26.0f));
        CGRect f = self.frame;
        f.size.width = targetWidth;
        self.frame = f;
        self.titleLabel.frame = CGRectMake(17.0f, 0.0f, targetWidth - 23.0f, 20.0f);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self updateAppearance];
        });
        return;
    } else if (res == InstagramDash1440pCheckResultArmed) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
    } else {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }

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
    BOOL isForced = InstagramDash1440p_IsForce1440pActive();
    NSString *repId = InstagramDash1440p_GetCurrentRepresentationId() ?: @"ready";

    NSString *text = nil;
    if (!isForced) {
        text = [NSString stringWithFormat:@"OFF (IG Default): %@", repId];
        self.layer.borderColor = [UIColor colorWithWhite:0.6f alpha:0.45f].CGColor;
        self.statusDot.backgroundColor = [UIColor colorWithWhite:0.6f alpha:0.8f];
        self.titleLabel.textColor = [UIColor colorWithWhite:0.75f alpha:1.0f];
    } else {
        text = [NSString stringWithFormat:@"Forced [1440p]: %@", repId];
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
// HUD Manager for InstagramDash1440p
// ============================================================================
@interface InstagramDash1440pHUDManager ()

@property (nonatomic, strong) InstagramDash1440pOverlayWindow *overlayWindow;
@property (nonatomic, strong) InstagramDash1440pPill *dashPill;

@end

@implementation InstagramDash1440pHUDManager

+ (instancetype)sharedManager {
    static InstagramDash1440pHUDManager *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[InstagramDash1440pHUDManager alloc] init];
    });
    return sShared;
}

- (void)forceCheckAndFetch1440p {
    InstagramDash1440p_ForceCheckAndFetch1440p();
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
            self.overlayWindow.windowLevel = UIWindowLevelNormal + 1001.0f;
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

        if (!self.dashPill) {
            CGFloat pillW = 140.0f;
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
    });
}

@end

// ============================================================================
// Auto-Initialization Constructor
// ============================================================================
__attribute__((constructor))
static void InstagramDash1440pUIAutoInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        [[InstagramDash1440pHUDManager sharedManager] startOverlay];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[InstagramDash1440pHUDManager sharedManager] startOverlay];
    });
}
