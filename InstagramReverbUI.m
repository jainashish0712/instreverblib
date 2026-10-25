// InstagramReverbUI.m
// Floating Draggable HUD & Control Overlay for InstagramReverb
// Right-hand ergonomic mini-widget, half-screen width, compact slider thumbs, +/- stepper buttons

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import "InstagramReverbUI.h"
#import "InstagramReverb.h"

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
    if (hitView == self || hitView == self.rootViewController.view) {
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
// HUD Manager Singleton
// ============================================================================
@interface InstagramReverbHUDManager ()
@property (nonatomic, strong) InstagramReverbOverlayWindow *overlayWindow;
@property (nonatomic, strong) InstagramReverbFloatingButton *floatingButton;
@property (nonatomic, strong) UIView *dimBackgroundView;
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

        UIView *container = self.overlayWindow.rootViewController.view;
        if (!container) return;

        CGRect winBounds = container.bounds;

        // Very light dimming (0.15) so background video remains visible
        if (!self.dimBackgroundView) {
            self.dimBackgroundView = [[UIView alloc] initWithFrame:winBounds];
            self.dimBackgroundView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.15f];
            self.dimBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            UITapGestureRecognizer *tapDim = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideHUD)];
            [self.dimBackgroundView addGestureRecognizer:tapDim];
        } else {
            self.dimBackgroundView.frame = winBounds;
        }

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

        [container addSubview:self.dimBackgroundView];
        [container addSubview:self.hudView];
        [container bringSubviewToFront:self.hudView];

        // Smooth spring animation
        self.dimBackgroundView.alpha = 0.0f;
        self.hudView.alpha = 0.0f;
        self.hudView.transform = CGAffineTransformMakeScale(0.85f, 0.85f);
        self.isHUDVisible = YES;

        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85f initialSpringVelocity:0.5f options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.dimBackgroundView.alpha = 1.0f;
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
            self.dimBackgroundView.alpha = 0.0f;
            self.hudView.alpha = 0.0f;
            self.hudView.transform = CGAffineTransformMakeScale(0.85f, 0.85f);
        } completion:^(BOOL finished) {
            [self.dimBackgroundView removeFromSuperview];
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
