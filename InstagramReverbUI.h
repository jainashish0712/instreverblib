// InstagramReverbUI.h
// Floating Draggable HUD & Control Overlay for InstagramReverb
// Thread-safe, main-thread guaranteed, zero private APIs

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface InstagramReverbHUDManager : NSObject

+ (instancetype)sharedManager;

// Start observing app lifecycle to attach floating control button
- (void)startOverlay;

// Programmatically show, hide, or toggle the Reverb HUD
- (void)showHUD;
- (void)hideHUD;
- (void)toggleHUD;

// Badges visibility control (DASH Quality & Performance Telemetry)
- (BOOL)areBadgesHidden;
- (void)setBadgesHidden:(BOOL)hidden;
- (void)toggleBadgesHidden;

// Force 1440p on-demand trigger
- (void)forceCheckAndFetch1440p;

@end

NS_ASSUME_NONNULL_END
