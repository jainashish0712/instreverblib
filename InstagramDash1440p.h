// InstagramDash1440p.h
// Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram
// Supports active on-screen Reel playback and off-screen background feed prefetching

#ifndef InstagramDash1440p_h
#define InstagramDash1440p_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, InstagramDash1440pMode) {
    InstagramDash1440pMode_MaxResolution = 0,      // Mode 1: 1440p / 1080p Max (Never 720p, 1440p forced on all 1440p reels)
    InstagramDash1440pMode_CellularSpoof1080p = 1, // Mode 2: Cellular spoofed to Wi-Fi for 1080p reels for all (Capped at 1080p, No 720p)
    InstagramDash1440pMode_Disabled = 2            // Mode 3: Disabled (Strictly native Instagram default behaviour)
};

// Master initialization
void InstagramDash1440p_Init(void);

// Mode control & cycling
InstagramDash1440pMode InstagramDash1440p_GetMode(void);
void InstagramDash1440p_SetMode(InstagramDash1440pMode mode);
InstagramDash1440pMode InstagramDash1440p_CycleMode(void);
NSString *InstagramDash1440p_GetModeName(InstagramDash1440pMode mode);

// Toggles & state (Legacy compatibility)
BOOL InstagramDash1440p_IsEnabled(void);
void InstagramDash1440p_SetEnabled(BOOL enabled);
BOOL InstagramDash1440p_ToggleEnabled(void);

// Real-time telemetry
BOOL InstagramDash1440p_IsActual1440p(void);
NSString *InstagramDash1440p_GetCurrentQuality(void);
NSString *InstagramDash1440p_GetCurrentResolution(void);
NSString *InstagramDash1440p_GetCurrentRepresentationId(void);
NSString *InstagramDash1440p_GetLogFilePath(void);

// Notification posted when active stream quality or representation ID changes
extern NSString * const kInstagramDash1440pStateDidChangeNotification;

#ifdef __cplusplus
}
#endif

#endif /* InstagramDash1440p_h */
