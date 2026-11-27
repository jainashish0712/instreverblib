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

// Toggle the floating badges (1440p pill + perf pill); returns YES if now hidden.
// Also stops perf-pill polling when hidden (battery). Persists via "InstagramReverb_badgesHidden".
- (BOOL)toggleBadges;

@end

// Autonomous & Manual Container Cache Cleaner API
void InstagramCacheCleaner_StartAutonomousMaintenance(void);
uint64_t InstagramCacheCleaner_PerformClean(NSTimeInterval minAgeSeconds);
void InstagramCacheCleaner_CheckpointSQLiteWAL(void);

NS_ASSUME_NONNULL_END
