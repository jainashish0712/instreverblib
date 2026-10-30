// InstagramDash1440p.h
// Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram
// Supports active on-screen Reel playback and root-level manifest pruning

#ifndef InstagramDash1440p_h
#define InstagramDash1440p_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Streaming Modes
typedef NS_ENUM(NSInteger, InstagramDash1440pMode) {
    InstagramDash1440pModeWifiOnly = 0,     // Legacy compatibility
    InstagramDash1440pModeAlways1440p = 1,  // Force 1440p Active
    InstagramDash1440pModeDisabled = 2       // Disabled: Native Instagram ABR & Playback
};

// Force Check and Fetch 1440p
typedef NS_ENUM(NSInteger, InstagramDash1440pCheckResult) {
    InstagramDash1440pCheckResultDisabled = 0,             // Toggled off; native Instagram behavior
    InstagramDash1440pCheckResult1440pFoundAndForced = 1,  // 1440p stream detected and forced
    InstagramDash1440pCheckResult1440pNotAvailable = 2,    // Reel does not have a 1440p stream on CDN (max 1080p)
    InstagramDash1440pCheckResultArmed = 3                 // Armed to force 1440p on next playing reel
};

// Master initialization
void InstagramDash1440p_Init(void);

// On-Demand Force Check & Fetch
InstagramDash1440pCheckResult InstagramDash1440p_ForceCheckAndFetch1440p(void);
BOOL InstagramDash1440p_IsForce1440pActive(void);
void InstagramDash1440p_SetForce1440pActive(BOOL active);

// Mode & State Management
InstagramDash1440pMode InstagramDash1440p_GetMode(void);
void InstagramDash1440p_SetMode(InstagramDash1440pMode mode);
InstagramDash1440pMode InstagramDash1440p_CycleMode(void);
NSString *InstagramDash1440p_GetModeName(void);

// Legacy toggle compatibility
BOOL InstagramDash1440p_IsEnabled(void);
void InstagramDash1440p_SetEnabled(BOOL enabled);
BOOL InstagramDash1440p_ToggleEnabled(void);

// Real-time telemetry
BOOL InstagramDash1440p_IsActual1440p(void);
NSString *InstagramDash1440p_GetCurrentQuality(void);
NSString *InstagramDash1440p_GetCurrentResolution(void);
NSString *InstagramDash1440p_GetCurrentRepresentationId(void);
NSString *InstagramDash1440p_GetLogFilePath(void);

// Notification posted when active stream quality, mode, or representation ID changes
extern NSString * const kInstagramDash1440pStateDidChangeNotification;

#ifdef __cplusplus
}
#endif

#endif /* InstagramDash1440p_h */
