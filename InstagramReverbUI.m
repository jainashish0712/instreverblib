// InstagramReverbUI.m
// Floating Draggable HUD & Control Overlay for InstagramReverb
// Right-hand ergonomic mini-widget, half-screen width, compact slider thumbs, +/- stepper buttons

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import "InstagramReverbUI.h"
#import "InstagramReverb.h"
#import "InstagramDash1440p.h"

// Accent Color: Vibrant Neon Green #1DB954 for maximum visibility and contrast
#define ACCENT_COLOR [UIColor colorWithRed:(29.0f/255.0f) green:(185.0f/255.0f) blue:(84.0f/255.0f) alpha:1.0f]

// Generates a sleek, compact circular slider thumb (11pt diameter with subtle shadow)
static UIImage *CreateCompactThumb(CGFloat diameter) {
    CGFloat canvasSize = diameter + 4.0f;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasSize, canvasSize), NO, 0.0f);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1.0f), 1.5f, [UIColor colorWithWhite:0 alpha:0.30f].CGColor);
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(2.0f, 2.0f, diameter, diameter));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Generates a tiny, sleek +/- stepper button with expanded touch target
static UIButton *CreateTinyStepButton(NSString *title) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:0.95f alpha:1.0f] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
    btn.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.12f];
    btn.layer.cornerRadius = 3.5f;
    btn.layer.masksToBounds = YES;
    return btn;
}

// ============================================================================
// Passthrough Overlay Window (Always Floats Above Reels, Stories & Modals)
// ============================================================================
@interface InstagramReverbOverlayWindow : UIWindow
@end

@implementation InstagramReverbOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (!hitView || hitView == self || hitView == self.rootViewController.view) {
        return nil; // Pass touches through to Instagram
    }
    return hitView;
}

@end

@interface InstagramReverbOverlayViewController : UIViewController
@end

@implementation InstagramReverbOverlayViewController

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
// Floating Draggable Pill Button
// ============================================================================
@interface InstagramReverbFloatingButton : UIView

@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, copy) void (^tapHandler)(void);

@end

@implementation InstagramReverbFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0f;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.5f;
        self.layer.borderColor = ACCENT_COLOR.CGColor;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _label = [[UILabel alloc] initWithFrame:self.bounds];
        _label.text = @"🎛️";
        _label.font = [UIFont systemFontOfSize:22.0f];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (self.tapHandler) {
        self.tapHandler();
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

        CGRect bounds = superview.bounds;
        CGFloat radius = self.bounds.size.width / 2.0f;
        CGFloat minX = radius + 8.0f;
        CGFloat maxX = bounds.size.width - radius - 8.0f;
        CGFloat minY = radius + 40.0f;
        CGFloat maxY = bounds.size.height - radius - 40.0f;

        center.x = MAX(minX, MIN(maxX, center.x));
        center.y = MAX(minY, MIN(maxY, center.y));

        self.center = center;
        [pan setTranslation:CGPointMake(0, 0) inView:superview];
    }
}

@end

// ============================================================================
// Separate Thin Vertical 70x20px Draggable System Volume Bar
// ============================================================================
@interface InstagramReverbVolumeBar : UIView

@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) MPVolumeView *internalVolumeView;
@property (nonatomic, strong) NSTimer *inactivityTimer;

// Touch, Swipe & 4-Second Hold Drag State
@property (nonatomic, strong) NSTimer *holdTimer;
@property (nonatomic, assign) CGPoint touchDownPoint;
@property (nonatomic, assign) float touchDownVolume;
@property (nonatomic, assign) BOOL isSwipingVolume;
@property (nonatomic, assign) BOOL isDraggingBar;

- (float)currentSystemVolume;
- (void)updateFillForVolume:(float)volume;
- (void)setSystemVolume:(float)volume;
- (void)revealAndResetTimer;

@end

@implementation InstagramReverbVolumeBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 10.0f;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5f;
        self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
        self.backgroundColor = [UIColor colorWithWhite:0.10f alpha:0.65f];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _trackView = [[UIView alloc] initWithFrame:self.bounds];
        _trackView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.20f];
        _trackView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _trackView.userInteractionEnabled = NO;
        [self addSubview:_trackView];

        _fillView = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height, self.bounds.size.width, 0)];
        _fillView.backgroundColor = ACCENT_COLOR;
        _fillView.userInteractionEnabled = NO;
        [self addSubview:_fillView];

        // Offscreen MPVolumeView to programmatically set system volume
        _internalVolumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 1, 1)];
        _internalVolumeView.alpha = 0.01f;
        _internalVolumeView.userInteractionEnabled = NO;
        [self addSubview:_internalVolumeView];

        // Observers for system volume changes (hardware buttons, headphones, etc.)
        @try {
            [[AVAudioSession sharedInstance] addObserver:self
                                              forKeyPath:@"outputVolume"
                                                 options:NSKeyValueObservingOptionNew
                                                 context:nil];
        } @catch (NSException *e) {}

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(systemVolumeNotification:)
                                                     name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                   object:nil];

        [self updateFillForVolume:[self currentSystemVolume]];
    }
    return self;
}

- (void)dealloc {
    @try {
        [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
    } @catch (NSException *e) {}
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_holdTimer invalidate];
    [_inactivityTimer invalidate];
}

- (float)currentSystemVolume {
    return [[AVAudioSession sharedInstance] outputVolume];
}

- (void)updateFillForVolume:(float)volume {
    volume = fmaxf(0.0f, fminf(1.0f, volume));
    CGFloat h = self.bounds.size.height;
    CGFloat w = self.bounds.size.width;
    CGFloat fillH = roundf(h * volume);
    CGFloat fillY = h - fillH;
    self.fillView.frame = CGRectMake(0, fillY, w, fillH);
}

- (void)setSystemVolume:(float)volume {
    volume = fmaxf(0.0f, fminf(1.0f, volume));
    [self updateFillForVolume:volume];

    for (UIView *sub in self.internalVolumeView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)sub;
            slider.value = volume;
            [slider sendActionsForControlEvents:UIControlEventValueChanged];
            break;
        }
    }
}

- (void)revealAndResetTimer {
    [self.inactivityTimer invalidate];
    self.inactivityTimer = nil;

    if (self.alpha < 1.0f) {
        [UIView animateWithDuration:0.20 animations:^{
            self.alpha = 1.0f;
        }];
    }

    __weak typeof(self) weakSelf = self;
    self.inactivityTimer = [NSTimer timerWithTimeInterval:2.5
                                                   target:weakSelf
                                                 selector:@selector(fadeToTransparent)
                                                 userInfo:nil
                                                  repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.inactivityTimer forMode:NSRunLoopCommonModes];
}

- (void)fadeToTransparent {
    [UIView animateWithDuration:0.35 animations:^{
        self.alpha = 0.05f; // Keep min 5% opacity so it remains visible and directly touchable
    }];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];

    UITouch *touch = [touches anyObject];
    if (!touch) return;

    // Wake up bar to 100% opacity on touch; pause inactivity timer while touching
    [self.inactivityTimer invalidate];
    self.inactivityTimer = nil;
    if (self.alpha < 1.0f) {
        [UIView animateWithDuration:0.15 animations:^{
            self.alpha = 1.0f;
        }];
    }

    // Record initial touch state (NO volume change on touch!)
    self.touchDownPoint = [touch locationInView:self];
    self.touchDownVolume = [self currentSystemVolume];
    self.isSwipingVolume = NO;
    self.isDraggingBar = NO;

    // Start strict 4.0-second hold timer to unlock dragging anywhere
    [self.holdTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.holdTimer = [NSTimer timerWithTimeInterval:1.5
                                             target:weakSelf
                                           selector:@selector(handleHoldUnlocked)
                                           userInfo:nil
                                            repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.holdTimer forMode:NSRunLoopCommonModes];
}

- (void)handleHoldUnlocked {
    self.isDraggingBar = YES;
    self.isSwipingVolume = NO;

    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback impactOccurred];
    }

    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(1.18f, 1.18f);
        self.layer.borderColor = [UIColor whiteColor].CGColor;
    }];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];

    UITouch *touch = [touches anyObject];
    if (!touch) return;

    UIView *superview = self.superview;
    if (!superview) return;

    // 1. If 4-second hold unlocked, drag the bar anywhere across the screen
    if (self.isDraggingBar) {
        CGPoint pt = [touch locationInView:superview];
        CGRect bounds = superview.bounds;
        CGFloat halfW = self.bounds.size.width / 2.0f;
        CGFloat halfH = self.bounds.size.height / 2.0f;
        CGFloat minX = halfW + 4.0f;
        CGFloat maxX = bounds.size.width - halfW - 4.0f;
        CGFloat minY = halfH + 40.0f;
        CGFloat maxY = bounds.size.height - halfH - 20.0f;

        pt.x = fmaxf(minX, fminf(maxX, pt.x));
        pt.y = fmaxf(minY, fminf(maxY, pt.y));
        self.center = pt;
        return;
    }

    // 2. Otherwise check for intentional vertical swipe to change volume
    CGPoint currentPoint = [touch locationInView:self];
    CGFloat deltaY = self.touchDownPoint.y - currentPoint.y; // Upwards swipe increases volume

    if (!self.isSwipingVolume) {
        if (fabs(deltaY) >= 5.0f) {
            self.isSwipingVolume = YES;
            // Cancel hold timer since user is actively swiping volume
            [self.holdTimer invalidate];
            self.holdTimer = nil;
        }
    }

    if (self.isSwipingVolume) {
        // Swiping changes volume only while actively swiping; bar position stays fixed
        float newVol = self.touchDownVolume + (float)(deltaY / self.bounds.size.height);
        newVol = fmaxf(0.0f, fminf(1.0f, newVol));
        [self setSystemVolume:newVol];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];

    [self.holdTimer invalidate];
    self.holdTimer = nil;

    if (self.isDraggingBar) {
        self.isDraggingBar = NO;
        [UIView animateWithDuration:0.2 animations:^{
            self.transform = CGAffineTransformIdentity;
            self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
        }];
    }

    self.isSwipingVolume = NO;
    [self revealAndResetTimer];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];

    [self.holdTimer invalidate];
    self.holdTimer = nil;

    if (self.isDraggingBar) {
        self.isDraggingBar = NO;
        [UIView animateWithDuration:0.2 animations:^{
            self.transform = CGAffineTransformIdentity;
            self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
        }];
    }

    self.isSwipingVolume = NO;
    [self revealAndResetTimer];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"outputVolume"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            float vol = [[AVAudioSession sharedInstance] outputVolume];
            [self updateFillForVolume:vol];
            [self revealAndResetTimer];
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)systemVolumeNotification:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        float vol = [[AVAudioSession sharedInstance] outputVolume];
        NSDictionary *userInfo = note.userInfo;
        if (userInfo && userInfo[@"AVSystemController_AudioVolumeNotificationParameter"]) {
            vol = [userInfo[@"AVSystemController_AudioVolumeNotificationParameter"] floatValue];
        }
        [self updateFillForVolume:vol];
        [self revealAndResetTimer];
    });
}

@end

// ============================================================================
// Modal Reverb & Pitch HUD View (Compact Half-Screen Right-Hand Mini-Widget)
// ============================================================================
@interface InstagramReverbHUDView : UIView <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeBtn;
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UIView *separator;

// 1. Pitch Shift Controls
@property (nonatomic, strong) UILabel *pitchTitleLabel;
@property (nonatomic, strong) UIButton *pitchMinusBtn;
@property (nonatomic, strong) UIButton *pitchPlusBtn;
@property (nonatomic, strong) UILabel *pitchValLabel;
@property (nonatomic, strong) UISlider *pitchSlider;

// 2. Reverb Wet/Dry Mix Controls
@property (nonatomic, strong) UILabel *mixTitleLabel;
@property (nonatomic, strong) UIButton *mixMinusBtn;
@property (nonatomic, strong) UIButton *mixPlusBtn;
@property (nonatomic, strong) UILabel *mixValLabel;
@property (nonatomic, strong) UISlider *mixSlider;

// 3. Room Size (Decay) Controls
@property (nonatomic, strong) UILabel *roomTitleLabel;
@property (nonatomic, strong) UIButton *roomMinusBtn;
@property (nonatomic, strong) UIButton *roomPlusBtn;
@property (nonatomic, strong) UILabel *roomValLabel;
@property (nonatomic, strong) UISlider *roomSlider;

// 4. System Volume Controls
@property (nonatomic, strong) UILabel *volumeTitleLabel;
@property (nonatomic, strong) UIButton *volumeMinusBtn;
@property (nonatomic, strong) UIButton *volumePlusBtn;
@property (nonatomic, strong) UILabel *volumeValLabel;
@property (nonatomic, strong) MPVolumeView *volumeView;

// 5. Reset Defaults Button
@property (nonatomic, strong) UIButton *resetBtn;
@property (nonatomic, copy) void (^closeHandler)(void);

- (void)refreshValues;

@end

@implementation InstagramReverbHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 14.0f;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5f;
        self.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.18f].CGColor;
        self.backgroundColor = [UIColor colorWithWhite:0.08f alpha:0.62f];

        // 50% blur intensity background effect
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.alpha = 0.50f;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        _contentContainer = [[UIView alloc] initWithFrame:self.bounds];
        _contentContainer.backgroundColor = [UIColor clearColor];
        _contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_contentContainer];

        // Header: Scaled compact title + toggle + close
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = @"Reverb & Pitch";
        _titleLabel.font = [UIFont boldSystemFontOfSize:11.5f];
        _titleLabel.textColor = [UIColor whiteColor];
        [_contentContainer addSubview:_titleLabel];

        _enableSwitch = [[UISwitch alloc] init];
        _enableSwitch.onTintColor = ACCENT_COLOR;
        _enableSwitch.transform = CGAffineTransformMakeScale(0.58f, 0.58f);
        [_enableSwitch addTarget:self action:@selector(enableToggled:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:_enableSwitch];

        _closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [_closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        _closeBtn.titleLabel.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightMedium];
        [_closeBtn setTitleColor:[UIColor colorWithWhite:0.75f alpha:1.0f] forState:UIControlStateNormal];
        [_closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_closeBtn];

        _separator = [[UIView alloc] init];
        _separator.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.12f];
        [_contentContainer addSubview:_separator];

        // Sleek compact 11pt slider thumbs
        UIImage *thumb = CreateCompactThumb(11.0f);

        // 1. Pitch Shift Row (-4.0 to +4.0 in 0.2 intervals)
        _pitchTitleLabel = [[UILabel alloc] init];
        _pitchTitleLabel.text = @"Pitch";
        _pitchTitleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
        _pitchTitleLabel.textColor = [UIColor whiteColor];
        [_contentContainer addSubview:_pitchTitleLabel];

        _pitchMinusBtn = CreateTinyStepButton(@"-");
        [_pitchMinusBtn addTarget:self action:@selector(pitchMinusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_pitchMinusBtn];

        _pitchPlusBtn = CreateTinyStepButton(@"+");
        [_pitchPlusBtn addTarget:self action:@selector(pitchPlusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_pitchPlusBtn];

        _pitchValLabel = [[UILabel alloc] init];
        _pitchValLabel.textAlignment = NSTextAlignmentRight;
        _pitchValLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightRegular];
        _pitchValLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
        [_contentContainer addSubview:_pitchValLabel];

        _pitchSlider = [[UISlider alloc] init];
        _pitchSlider.minimumValue = -4.0f;
        _pitchSlider.maximumValue = 4.0f;
        _pitchSlider.value = 0.0f;
        _pitchSlider.minimumTrackTintColor = ACCENT_COLOR;
        [_pitchSlider setThumbImage:thumb forState:UIControlStateNormal];
        [_pitchSlider setThumbImage:thumb forState:UIControlStateHighlighted];
        [_pitchSlider addTarget:self action:@selector(pitchChanged:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:_pitchSlider];

        // 2. Reverb Mix Row (0% to 100% in 8% intervals)
        _mixTitleLabel = [[UILabel alloc] init];
        _mixTitleLabel.text = @"Reverb";
        _mixTitleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
        _mixTitleLabel.textColor = [UIColor whiteColor];
        [_contentContainer addSubview:_mixTitleLabel];

        _mixMinusBtn = CreateTinyStepButton(@"-");
        [_mixMinusBtn addTarget:self action:@selector(mixMinusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_mixMinusBtn];

        _mixPlusBtn = CreateTinyStepButton(@"+");
        [_mixPlusBtn addTarget:self action:@selector(mixPlusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_mixPlusBtn];

        _mixValLabel = [[UILabel alloc] init];
        _mixValLabel.textAlignment = NSTextAlignmentRight;
        _mixValLabel.font = [UIFont systemFontOfSize:9.0f weight:UIFontWeightRegular];
        _mixValLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
        _mixValLabel.adjustsFontSizeToFitWidth = YES;
        _mixValLabel.minimumScaleFactor = 0.75f;
        [_contentContainer addSubview:_mixValLabel];

        _mixSlider = [[UISlider alloc] init];
        _mixSlider.minimumValue = 0.0f;
        _mixSlider.maximumValue = 1.0f;
        _mixSlider.value = 0.35f;
        _mixSlider.minimumTrackTintColor = ACCENT_COLOR;
        [_mixSlider setThumbImage:thumb forState:UIControlStateNormal];
        [_mixSlider setThumbImage:thumb forState:UIControlStateHighlighted];
        [_mixSlider addTarget:self action:@selector(mixChanged:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:_mixSlider];

        // 3. Room Size Row (0.10 to 0.98 in 0.08 intervals)
        _roomTitleLabel = [[UILabel alloc] init];
        _roomTitleLabel.text = @"Room";
        _roomTitleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
        _roomTitleLabel.textColor = [UIColor whiteColor];
        [_contentContainer addSubview:_roomTitleLabel];

        _roomMinusBtn = CreateTinyStepButton(@"-");
        [_roomMinusBtn addTarget:self action:@selector(roomMinusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_roomMinusBtn];

        _roomPlusBtn = CreateTinyStepButton(@"+");
        [_roomPlusBtn addTarget:self action:@selector(roomPlusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_roomPlusBtn];

        _roomValLabel = [[UILabel alloc] init];
        _roomValLabel.textAlignment = NSTextAlignmentRight;
        _roomValLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightRegular];
        _roomValLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
        [_contentContainer addSubview:_roomValLabel];

        _roomSlider = [[UISlider alloc] init];
        _roomSlider.minimumValue = 0.1f;
        _roomSlider.maximumValue = 0.98f;
        _roomSlider.value = 0.82f;
        _roomSlider.minimumTrackTintColor = ACCENT_COLOR;
        [_roomSlider setThumbImage:thumb forState:UIControlStateNormal];
        [_roomSlider setThumbImage:thumb forState:UIControlStateHighlighted];
        [_roomSlider addTarget:self action:@selector(roomChanged:) forControlEvents:UIControlEventValueChanged];
        [_contentContainer addSubview:_roomSlider];

        // 4. System Volume Row (0% to 100% in 7% intervals)
        _volumeTitleLabel = [[UILabel alloc] init];
        _volumeTitleLabel.text = @"Volume";
        _volumeTitleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
        _volumeTitleLabel.textColor = [UIColor whiteColor];
        [_contentContainer addSubview:_volumeTitleLabel];

        _volumeMinusBtn = CreateTinyStepButton(@"-");
        [_volumeMinusBtn addTarget:self action:@selector(volumeMinusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_volumeMinusBtn];

        _volumePlusBtn = CreateTinyStepButton(@"+");
        [_volumePlusBtn addTarget:self action:@selector(volumePlusTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_volumePlusBtn];

        _volumeValLabel = [[UILabel alloc] init];
        _volumeValLabel.textAlignment = NSTextAlignmentRight;
        _volumeValLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightRegular];
        _volumeValLabel.textColor = [UIColor colorWithWhite:0.85f alpha:1.0f];
        [_contentContainer addSubview:_volumeValLabel];

        _volumeView = [[MPVolumeView alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _volumeView.showsRouteButton = NO;
#pragma clang diagnostic pop
        _volumeView.tintColor = ACCENT_COLOR;
        [_volumeView setVolumeThumbImage:thumb forState:UIControlStateNormal];
        [_volumeView setVolumeThumbImage:thumb forState:UIControlStateHighlighted];
        [_contentContainer addSubview:_volumeView];

        // 5. Reset Defaults Button (Compact)
        _resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_resetBtn setTitle:@"Reset to Defaults" forState:UIControlStateNormal];
        [_resetBtn setTitleColor:[UIColor colorWithWhite:0.75f alpha:1.0f] forState:UIControlStateNormal];
        _resetBtn.titleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
        _resetBtn.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.07f];
        _resetBtn.layer.cornerRadius = 5.0f;
        [_resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
        [_contentContainer addSubview:_resetBtn];

        // Draggable Pan Gesture for HUD (without interfering with sliders or buttons)
        UIPanGestureRecognizer *hudPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        hudPan.delegate = self;
        [self addGestureRecognizer:hudPan];

        [self refreshValues];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Let sliders, buttons, and switches handle their own touches directly
    if ([touch.view isKindOfClass:[UIControl class]] ||
        [touch.view.superview isKindOfClass:[UIControl class]] ||
        [touch.view isKindOfClass:[MPVolumeView class]] ||
        [touch.view.superview isKindOfClass:[MPVolumeView class]]) {
        return NO;
    }
    return YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [pan translationInView:superview];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

        CGRect bounds = superview.bounds;
        CGFloat halfW = self.bounds.size.width / 2.0f;
        CGFloat halfH = self.bounds.size.height / 2.0f;

        CGFloat minX = halfW + 6.0f;
        CGFloat maxX = bounds.size.width - halfW - 6.0f;
        CGFloat minY = halfH + 35.0f;
        CGFloat maxY = bounds.size.height - halfH - 25.0f;

        center.x = MAX(minX, MIN(maxX, center.x));
        center.y = MAX(minY, MIN(maxY, center.y));

        self.center = center;
        [pan setTranslation:CGPointMake(0, 0) inView:superview];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    _blurView.frame = self.bounds;
    _contentContainer.frame = self.bounds;

    CGFloat pad = 10.0f;
    CGFloat w = self.bounds.size.width - (pad * 2.0f);

    // Header (y = 8.0f)
    CGFloat y = 8.0f;
    _titleLabel.frame = CGRectMake(pad, y, w - 55.0f, 20.0f);
    _enableSwitch.center = CGPointMake(self.bounds.size.width - pad - 34.0f, y + 10.0f);
    _closeBtn.frame = CGRectMake(self.bounds.size.width - pad - 16.0f, y, 16.0f, 20.0f);

    y += 24.0f;
    _separator.frame = CGRectMake(pad, y, w, 0.5f);
    y += 5.0f;

    CGFloat rowH = 15.0f;
    CGFloat sliderH = 16.0f;
    CGFloat rowSpacing = 2.0f;
    CGFloat blockGap = 5.0f;

    CGFloat labelW = 40.0f;
    CGFloat btnW = 15.0f;
    CGFloat btnH = 14.0f;
    CGFloat btnGap = 3.0f;
    CGFloat minusX = pad + labelW + 2.0f;
    CGFloat plusX = minusX + btnW + btnGap;
    CGFloat valX = plusX + btnW + 4.0f;
    CGFloat valW = (pad + w) - valX;

    // 1. Pitch Shift Row
    _pitchTitleLabel.frame = CGRectMake(pad, y, labelW, rowH);
    _pitchMinusBtn.frame = CGRectMake(minusX, y + 0.5f, btnW, btnH);
    _pitchPlusBtn.frame = CGRectMake(plusX, y + 0.5f, btnW, btnH);
    _pitchValLabel.frame = CGRectMake(valX, y, valW, rowH);
    y += rowH + rowSpacing;
    _pitchSlider.frame = CGRectMake(pad, y, w, sliderH);
    y += sliderH + blockGap;

    // 2. Reverb Mix Row
    _mixTitleLabel.frame = CGRectMake(pad, y, labelW, rowH);
    _mixMinusBtn.frame = CGRectMake(minusX, y + 0.5f, btnW, btnH);
    _mixPlusBtn.frame = CGRectMake(plusX, y + 0.5f, btnW, btnH);
    _mixValLabel.frame = CGRectMake(valX, y, valW, rowH);
    y += rowH + rowSpacing;
    _mixSlider.frame = CGRectMake(pad, y, w, sliderH);
    y += sliderH + blockGap;

    // 3. Room Size Row
    _roomTitleLabel.frame = CGRectMake(pad, y, labelW, rowH);
    _roomMinusBtn.frame = CGRectMake(minusX, y + 0.5f, btnW, btnH);
    _roomPlusBtn.frame = CGRectMake(plusX, y + 0.5f, btnW, btnH);
    _roomValLabel.frame = CGRectMake(valX, y, valW, rowH);
    y += rowH + rowSpacing;
    _roomSlider.frame = CGRectMake(pad, y, w, sliderH);
    y += sliderH + blockGap;

    // 4. System Volume Row
    _volumeTitleLabel.frame = CGRectMake(pad, y, labelW, rowH);
    _volumeMinusBtn.frame = CGRectMake(minusX, y + 0.5f, btnW, btnH);
    _volumePlusBtn.frame = CGRectMake(plusX, y + 0.5f, btnW, btnH);
    _volumeValLabel.frame = CGRectMake(valX, y, valW, rowH);
    y += rowH + rowSpacing;
    _volumeView.frame = CGRectMake(pad, y, w, sliderH);
    y += sliderH + 6.0f;

    // Ensure volume subview slider has correct compact thumb, tint, and touch listener
    UIImage *thumb = CreateCompactThumb(11.0f);
    for (UIView *sub in _volumeView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            UISlider *volSlider = (UISlider *)sub;
            volSlider.tintColor = ACCENT_COLOR;
            [volSlider setThumbImage:thumb forState:UIControlStateNormal];
            [volSlider setThumbImage:thumb forState:UIControlStateHighlighted];
            [volSlider removeTarget:self action:@selector(volumeSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [volSlider addTarget:self action:@selector(volumeSliderChanged:) forControlEvents:UIControlEventValueChanged];
        }
    }

    // 5. Reset Defaults Button
    _resetBtn.frame = CGRectMake(pad, y, w, 22.0f);
}

- (void)refreshValues {
    self.enableSwitch.on = InstagramReverb_IsEnabled();

    // Pitch (-4.0 to +4.0 in 0.2 intervals)
    float pitch = InstagramReverb_GetPitch();
    self.pitchSlider.value = pitch;
    self.pitchValLabel.text = (fabsf(pitch) < 0.01f) ? @"0.0 st" : [NSString stringWithFormat:@"%+0.1f st", pitch];

    // Wet / Dry (strictly 100% complementary: dry% + wet% = 100%)
    float wet = InstagramReverb_GetWet();
    float dry = 1.0f - wet;
    self.mixSlider.value = wet;
    self.mixValLabel.text = [NSString stringWithFormat:@"Dry %.0f%% / Wet %.0f%%", dry * 100.0f, wet * 100.0f];

    // Room Size (0.10 to 0.98 in 0.08 intervals)
    float room = InstagramReverb_GetRoomSize();
    self.roomSlider.value = room;
    self.roomValLabel.text = [NSString stringWithFormat:@"%.2f", room];

    // Volume (0% to 100%)
    float currentVol = 0.5f;
    for (UIView *sub in self.volumeView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            currentVol = ((UISlider *)sub).value;
            break;
        }
    }
    self.volumeValLabel.text = [NSString stringWithFormat:@"%.0f%%", currentVol * 100.0f];
}

// ----------------------------------------------------------------------------
// Master On / Off Toggle
// ----------------------------------------------------------------------------
- (void)enableToggled:(UISwitch *)sender {
    InstagramReverb_SetEnabled(sender.on);
}

// ----------------------------------------------------------------------------
// Pitch Shift: Slider & +/- Step (Interval: 0.2 st)
// ----------------------------------------------------------------------------
- (void)pitchStep:(float)delta {
    float cur = InstagramReverb_GetPitch();
    float step = 0.2f;
    float nextVal = roundf((cur + delta) / step) * step;
    nextVal = fmaxf(-4.0f, fminf(4.0f, nextVal));
    self.pitchSlider.value = nextVal;
    InstagramReverb_SetPitch(nextVal);
    self.pitchValLabel.text = (fabsf(nextVal) < 0.01f) ? @"0.0 st" : [NSString stringWithFormat:@"%+0.1f st", nextVal];
}

- (void)pitchMinusTapped {
    [self pitchStep:-0.2f];
}

- (void)pitchPlusTapped {
    [self pitchStep:0.2f];
}

- (void)pitchChanged:(UISlider *)sender {
    float step = 0.2f;
    float val = roundf(sender.value / step) * step;
    sender.value = val;
    InstagramReverb_SetPitch(val);
    self.pitchValLabel.text = (fabsf(val) < 0.01f) ? @"0.0 st" : [NSString stringWithFormat:@"%+0.1f st", val];
}

// ----------------------------------------------------------------------------
// Reverb Mix: Slider & +/- Step (Interval: 8% / 0.08)
// ----------------------------------------------------------------------------
- (void)mixStep:(float)delta {
    float curWet = InstagramReverb_GetWet();
    float newWet = fmaxf(0.0f, fminf(1.0f, curWet + delta));
    newWet = roundf(newWet * 100.0f) / 100.0f;
    float newDry = 1.0f - newWet;
    self.mixSlider.value = newWet;
    InstagramReverb_SetWetDry(newWet, newDry);
    self.mixValLabel.text = [NSString stringWithFormat:@"Dry %.0f%% / Wet %.0f%%", newDry * 100.0f, newWet * 100.0f];
}

- (void)mixMinusTapped {
    [self mixStep:-0.08f];
}

- (void)mixPlusTapped {
    [self mixStep:0.08f];
}

- (void)mixChanged:(UISlider *)sender {
    float wet = sender.value;
    float dry = 1.0f - wet;
    InstagramReverb_SetWetDry(wet, dry);
    self.mixValLabel.text = [NSString stringWithFormat:@"Dry %.0f%% / Wet %.0f%%", dry * 100.0f, wet * 100.0f];
}

// ----------------------------------------------------------------------------
// Room Size: Slider & +/- Step (Interval: 0.08)
// ----------------------------------------------------------------------------
- (void)roomStep:(float)delta {
    float curRoom = InstagramReverb_GetRoomSize();
    float newRoom = fmaxf(0.10f, fminf(0.98f, curRoom + delta));
    newRoom = roundf(newRoom * 100.0f) / 100.0f;
    self.roomSlider.value = newRoom;
    InstagramReverb_SetRoomSize(newRoom);
    self.roomValLabel.text = [NSString stringWithFormat:@"%.2f", newRoom];
}

- (void)roomMinusTapped {
    [self roomStep:-0.08f];
}

- (void)roomPlusTapped {
    [self roomStep:0.08f];
}

- (void)roomChanged:(UISlider *)sender {
    InstagramReverb_SetRoomSize(sender.value);
    self.roomValLabel.text = [NSString stringWithFormat:@"%.2f", sender.value];
}

// ----------------------------------------------------------------------------
// System Volume: Slider & +/- Step (Interval: 7% / 0.07)
// ----------------------------------------------------------------------------
- (void)volumeStep:(float)delta {
    for (UIView *sub in self.volumeView.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)sub;
            float newVol = fmaxf(0.0f, fminf(1.0f, slider.value + delta));
            newVol = roundf(newVol * 100.0f) / 100.0f;
            [slider setValue:newVol animated:YES];
            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
            self.volumeValLabel.text = [NSString stringWithFormat:@"%.0f%%", newVol * 100.0f];
            break;
        }
    }
}

- (void)volumeMinusTapped {
    [self volumeStep:-0.07f];
}

- (void)volumePlusTapped {
    [self volumeStep:0.07f];
}

- (void)volumeSliderChanged:(UISlider *)sender {
    self.volumeValLabel.text = [NSString stringWithFormat:@"%.0f%%", sender.value * 100.0f];
}

// ----------------------------------------------------------------------------
// Reset Defaults & Close Handlers
// ----------------------------------------------------------------------------
- (void)resetTapped {
    InstagramReverb_ResetDefaults();
    [self refreshValues];
}

- (void)closeTapped {
    if (self.closeHandler) {
        self.closeHandler();
    }
}

@end

// ============================================================================
// 20px 1440p DASH Filename Modal & Runtime Toggle Badge
// ============================================================================
@interface InstagramDash1440pModal : UIView

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UIVisualEffectView *blurView;

- (void)updateAppearanceWithFilename:(NSString *)filename isEnabled:(BOOL)isEnabled;

@end

@implementation InstagramDash1440pModal

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 10.0f; // Pill shape for 20px height
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0f;
        self.backgroundColor = [UIColor clearColor];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        // Tiny 5px status indicator dot
        _statusDot = [[UIView alloc] initWithFrame:CGRectMake(8.0f, 7.5f, 5.0f, 5.0f)];
        _statusDot.layer.cornerRadius = 2.5f;
        _statusDot.layer.masksToBounds = YES;
        _statusDot.userInteractionEnabled = NO;
        [self addSubview:_statusDot];

        // Filename & Status Text Label
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(17.0f, 0.0f, frame.size.width - 23.0f, 20.0f)];
        _titleLabel.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.textAlignment = NSTextAlignmentLeft;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        // Tap gesture to toggle 1440p on/off
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        // Pan gesture to drag modal anywhere on screen
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        // Subscribe to DASH state change notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onDashStateChanged:)
                                                     name:kInstagramDash1440pStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // Expand touch bounds vertically to 40pt for effortless tapping on mobile touchscreens
    CGRect touchArea = CGRectInset(self.bounds, -6.0f, -10.0f);
    return CGRectContainsPoint(touchArea, point);
}

- (void)updateAppearance {
    BOOL isEnabled = InstagramDash1440p_IsEnabled();
    NSString *quality = InstagramDash1440p_GetCurrentQuality() ?: @"1080p";
    NSString *cleanName = InstagramDash1440p_GetCurrentFilename() ?: @"fdash-ready";

    NSString *text;
    if (isEnabled) {
        text = [NSString stringWithFormat:@"%@: %@", quality, cleanName];
    } else {
        text = [NSString stringWithFormat:@"STD (%@): %@", quality, cleanName];
    }
    self.titleLabel.text = text;

    CGSize fit = [self.titleLabel sizeThatFits:CGSizeMake(320.0f, 20.0f)];
    CGFloat targetWidth = MAX(120.0f, MIN(320.0f, fit.width + 26.0f));

    CGRect f = self.frame;
    f.size.width = targetWidth;
    f.size.height = 20.0f; // Strictly 20px modal height
    self.frame = f;
    self.titleLabel.frame = CGRectMake(17.0f, 0.0f, targetWidth - 23.0f, 20.0f);

    if (isEnabled) {
        if ([quality isEqualToString:@"1440p"]) {
            // Actual 1440p stream: Vibrant Cyan
            self.layer.borderColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:0.90f].CGColor;
            self.statusDot.backgroundColor = [UIColor colorWithRed:(0.0f/255.0f) green:(229.0f/255.0f) blue:(255.0f/255.0f) alpha:1.0f];
        } else {
            // Actual 1080p stream: Bright Emerald Green
            self.layer.borderColor = [UIColor colorWithRed:(29.0f/255.0f) green:(185.0f/255.0f) blue:(84.0f/255.0f) alpha:0.85f].CGColor;
            self.statusDot.backgroundColor = [UIColor colorWithRed:(29.0f/255.0f) green:(185.0f/255.0f) blue:(84.0f/255.0f) alpha:1.0f];
        }
        self.titleLabel.textColor = [UIColor whiteColor];
    } else {
        // Disabled standard behavior state: Translucent grey
        self.layer.borderColor = [UIColor colorWithWhite:0.6f alpha:0.45f].CGColor;
        self.statusDot.backgroundColor = [UIColor colorWithWhite:0.5f alpha:0.6f];
        self.titleLabel.textColor = [UIColor colorWithWhite:0.75f alpha:1.0f];
    }
}

- (void)updateAppearanceWithFilename:(NSString *)filename isEnabled:(BOOL)isEnabled {
    [self updateAppearance];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];

    InstagramDash1440p_ToggleEnabled();
    [self updateAppearance];

    [UIView animateWithDuration:0.10 animations:^{
        self.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            self.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);

    CGFloat halfW = self.bounds.size.width / 2.0f;
    CGFloat halfH = self.bounds.size.height / 2.0f;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;

    newCenter.x = MAX(halfW + 6.0f, MIN(screenW - halfW - 6.0f, newCenter.x));
    newCenter.y = MAX(halfH + 30.0f, MIN(screenH - halfH - 30.0f, newCenter.y));

    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:self.superview];
}

- (void)onDashStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAppearance];
    });
}

@end

// ============================================================================
// HUD Manager Singleton
// ============================================================================
@interface InstagramReverbHUDManager ()
@property (nonatomic, strong) InstagramReverbOverlayWindow *overlayWindow;
@property (nonatomic, strong) InstagramReverbFloatingButton *floatingButton;
@property (nonatomic, strong) InstagramReverbVolumeBar *volumeBar;
@property (nonatomic, strong) InstagramDash1440pModal *dashModal;
@property (nonatomic, strong) InstagramReverbHUDView *hudView;
@property (nonatomic, assign) BOOL isHUDVisible;
@end

@implementation InstagramReverbHUDManager

+ (instancetype)sharedManager {
    static InstagramReverbHUDManager *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[InstagramReverbHUDManager alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isHUDVisible = NO;
    }
    return self;
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
                    self.overlayWindow = [[InstagramReverbOverlayWindow alloc] initWithWindowScene:scene];
                } else {
                    self.overlayWindow = [[InstagramReverbOverlayWindow alloc] initWithFrame:screenBounds];
                }
            } else {
                self.overlayWindow = [[InstagramReverbOverlayWindow alloc] initWithFrame:screenBounds];
            }
            self.overlayWindow.windowLevel = UIWindowLevelNormal + 1000.0f; // Above Reels, Stories & modals
            self.overlayWindow.backgroundColor = [UIColor clearColor];
            self.overlayWindow.rootViewController = [[InstagramReverbOverlayViewController alloc] init];
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

        if (!self.floatingButton) {
            CGFloat btnSize = 44.0f;
            CGFloat x = container.bounds.size.width - btnSize - 12.0f;
            CGFloat y = container.bounds.size.height - btnSize - 110.0f; // Above bottom tab bar
            self.floatingButton = [[InstagramReverbFloatingButton alloc] initWithFrame:CGRectMake(x, y, btnSize, btnSize)];

            __weak typeof(self) weakSelf = self;
            self.floatingButton.tapHandler = ^{
                [weakSelf toggleHUD];
            };
        }

        if (!self.floatingButton.superview) {
            [container addSubview:self.floatingButton];
            [container bringSubviewToFront:self.floatingButton];
        }

        // Separate Thin Vertical 70x20px Draggable System Volume Bar
        if (!self.volumeBar) {
            CGFloat barW = 20.0f;
            CGFloat barH = 70.0f;
            CGFloat initialX = 12.0f;
            CGFloat initialY = 240.0f;
            self.volumeBar = [[InstagramReverbVolumeBar alloc] initWithFrame:CGRectMake(initialX, initialY, barW, barH)];
            [container addSubview:self.volumeBar];
            [self.volumeBar updateFillForVolume:[self.volumeBar currentSystemVolume]];
            [self.volumeBar revealAndResetTimer];
        } else if (!self.volumeBar.superview) {
            [container addSubview:self.volumeBar];
            [self.volumeBar revealAndResetTimer];
        }

        // Small 20px 1440p DASH Reel Filename Modal & Runtime Toggle
        if (!self.dashModal) {
            CGFloat modalH = 20.0f;
            CGFloat modalW = 140.0f;
            CGFloat initialX = (container.bounds.size.width - modalW) / 2.0f;
            CGFloat initialY = 52.0f;
            self.dashModal = [[InstagramDash1440pModal alloc] initWithFrame:CGRectMake(initialX, initialY, modalW, modalH)];
            [container addSubview:self.dashModal];
            [self.dashModal updateAppearanceWithFilename:InstagramDash1440p_GetCurrentFilename()
                                               isEnabled:InstagramDash1440p_IsEnabled()];
        } else if (!self.dashModal.superview) {
            [container addSubview:self.dashModal];
            [self.dashModal updateAppearanceWithFilename:InstagramDash1440p_GetCurrentFilename()
                                               isEnabled:InstagramDash1440p_IsEnabled()];
        }

        static BOOL sGestureAdded = NO;
        if (!sGestureAdded) {
            UITapGestureRecognizer *twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleHUD)];
            twoFingerTap.numberOfTouchesRequired = 2;
            twoFingerTap.numberOfTapsRequired = 2;
            twoFingerTap.cancelsTouchesInView = NO;
            [self.overlayWindow addGestureRecognizer:twoFingerTap];
            sGestureAdded = YES;
        }
    });
}

- (void)toggleHUD {
    [self.volumeBar revealAndResetTimer];
    if (self.isHUDVisible) {
        [self hideHUD];
    } else {
        [self showHUD];
    }
}

- (void)showHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isHUDVisible) return;
        if (!self.overlayWindow) [self startOverlay];

        [self.volumeBar revealAndResetTimer];

        UIView *container = self.overlayWindow.rootViewController.view;
        if (!container) return;

        CGRect winBounds = container.bounds;

        // Compact Half-Screen Mini-Widget Layout:
        // Width ~196pt (strictly half of 393pt screen), docked to the bottom-right corner
        CGFloat screenW = winBounds.size.width;
        CGFloat screenH = winBounds.size.height;
        CGFloat rightMargin = 10.0f;
        CGFloat hudW = roundf(screenW * 0.50f); // Exactly half-screen width
        CGFloat hudH = 220.0f;                 // Scaled-down compact height with +/- steppers
        CGFloat hudX = screenW - hudW - rightMargin; // Right-hand corner docked
        CGFloat hudY = screenH - hudH - 95.0f;       // Bottom thumb sweep zone

        if (!self.hudView) {
            self.hudView = [[InstagramReverbHUDView alloc] initWithFrame:CGRectMake(hudX, hudY, hudW, hudH)];
            __weak typeof(self) weakSelf = self;
            self.hudView.closeHandler = ^{
                [weakSelf hideHUD];
            };
        } else {
            self.hudView.frame = CGRectMake(hudX, hudY, hudW, hudH);
            [self.hudView refreshValues];
        }

        // Add ONLY the HUD view to container. NO full-screen dim background view is added,
        // ensuring touches outside the HUD pass through completely to Instagram beneath.
        [container addSubview:self.hudView];
        [container bringSubviewToFront:self.hudView];

        // Smooth spring animation
        self.hudView.alpha = 0.0f;
        self.hudView.transform = CGAffineTransformMakeScale(0.85f, 0.85f);
        self.isHUDVisible = YES;

        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85f initialSpringVelocity:0.5f options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.hudView.alpha = 1.0f;
            self.hudView.transform = CGAffineTransformIdentity;
        } completion:nil];
    });
}

- (void)hideHUD {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isHUDVisible) return;
        self.isHUDVisible = NO;

        [UIView animateWithDuration:0.2 animations:^{
            self.hudView.alpha = 0.0f;
            self.hudView.transform = CGAffineTransformMakeScale(0.85f, 0.85f);
        } completion:^(BOOL finished) {
            [self.hudView removeFromSuperview];
        }];
    });
}

@end

// ============================================================================
// Auto-Register UI Overlay on App Launch
// ============================================================================
__attribute__((constructor))
static void InstagramReverbUIInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        [[InstagramReverbHUDManager sharedManager] startOverlay];
    }];
}
