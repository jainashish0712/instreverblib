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
    InstagramDash1440pModeWifiOnly = 0,     // Mode 1: Wi-Fi only 1440p (cellular capped to 1080p)
    InstagramDash1440pModeAlways1440p = 1,  // Mode 2: Wi-Fi and Cellular both max cap to 1440p
    InstagramDash1440pModeDisabled = 2       // Mode 3: Disable completely (Instagram default behavior)
};

// Master initialization
void InstagramDash1440p_Init(void);

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
