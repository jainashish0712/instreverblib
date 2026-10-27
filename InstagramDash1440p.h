// InstagramDash1440p.h
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unlocks full 1440p (2560x1440) DASH video playback on Wi-Fi and Cellular data by:
// 1. Overriding FNF player size pruning (reporting 1440x2560 viewport dimensions).
// 2. Disabling screen-width representation capping in FNFDashPlayerSizePruner.
// 3. Forcing selection of 1440p / maximum bitrate DASH video representations in FNFDashABRPlayerSizeQualitySelector.
// 4. Providing runtime toggle for standard vs 1440p DASH behavior.
// 5. Exposing exact server representation info ("fdash-%id") and actual quality resolution (1440p vs 1080p).

#ifndef InstagramDash1440p_h
#define InstagramDash1440p_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the DASH 1440p quality engine
void InstagramDash1440p_Init(void);

// Returns YES if DASH 1440p streaming is active
BOOL InstagramDash1440p_IsActive(void);

// Toggle controls for 1440p DASH forcing
BOOL InstagramDash1440p_IsEnabled(void);
void InstagramDash1440p_SetEnabled(BOOL enabled);
BOOL InstagramDash1440p_ToggleEnabled(void);

// Returns YES if current active stream is actually 1440p resolution
BOOL InstagramDash1440p_IsActual1440p(void);

// Returns quality label string ("1440p" or "1080p")
NSString *InstagramDash1440p_GetCurrentQuality(void);

// Current active fdash filename formatted as "fdash-%id"
NSString *InstagramDash1440p_GetCurrentFilename(void);
void InstagramDash1440p_SetCurrentFilename(NSString *filename);
void InstagramDash1440p_SetCurrentRepresentation(id rep);

// Notification posted when 1440p state, quality, or active filename updates
extern NSString * const kInstagramDash1440pStateDidChangeNotification;

#ifdef __cplusplus
}
#endif

#endif /* InstagramDash1440p_h */
