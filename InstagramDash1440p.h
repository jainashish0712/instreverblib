// InstagramDash1440p.h
// Ultra High-Definition (1440p / 2K) DASH Video Streaming Engine for Instagram
//
// Purpose:
// Unlocks full 1440p (2560x1440) DASH video playback on Wi-Fi by:
// 1. Overriding FNF player size pruning (reporting 1440x2560 viewport dimensions).
// 2. Disabling screen-width representation capping in FNFDashPlayerSizePruner.
// 3. Forcing selection of 1440p / maximum bitrate DASH video representations in FNFDashQualityManager.

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

#ifdef __cplusplus
}
#endif

#endif /* InstagramDash1440p_h */
