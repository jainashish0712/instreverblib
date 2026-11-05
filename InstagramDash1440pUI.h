// InstagramDash1440pUI.h
// Floating Draggable 1440p DASH Quality & Telemetry HUD Overlay for Instagram

#ifndef InstagramDash1440pUI_h
#define InstagramDash1440pUI_h

#import <UIKit/UIKit.h>

@interface InstagramDash1440pUIManager : NSObject
+ (instancetype)sharedManager;
- (void)startOverlay;
@end

#endif /* InstagramDash1440pUI_h */
