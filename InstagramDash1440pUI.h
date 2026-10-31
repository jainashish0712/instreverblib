// InstagramDash1440pUI.h
// Standalone Floating Draggable HUD & Quality Control Pill for InstagramDash1440p
// Thread-safe, main-thread guaranteed, zero private APIs

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface InstagramDash1440pHUDManager : NSObject

+ (instancetype)sharedManager;

// Start observing app lifecycle to attach floating 1440p DASH control pill
- (void)startOverlay;

// Programmatically trigger 1440p force check and fetch
- (void)forceCheckAndFetch1440p;

@end

NS_ASSUME_NONNULL_END
