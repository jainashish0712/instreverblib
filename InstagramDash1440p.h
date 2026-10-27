// InstagramDash1440p.h
// Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram
// Supports active on-screen Reel playback and off-screen background feed prefetching

#ifndef InstagramDash1440p_h
#define InstagramDash1440p_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Master initialization
void InstagramDash1440p_Init(void);

// Toggles & state
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
