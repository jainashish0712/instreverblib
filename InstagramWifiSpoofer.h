// InstagramWifiSpoofer.h
// Automatic Cellular-to-Wi-Fi Spoofing Engine for Instagram
//
// Purpose:
// Fakes cellular data connection as an active, unmetered, high-bandwidth Wi-Fi network
// so Instagram's Adaptive Bitrate (ABR) player (Sundial/FNF) unconditionally streams Reels
// and videos in full 1080p high quality without downscaling to 720p/480p on cellular data.
//
// 100% Automatic: Zero UI, zero toggles, permanently active in background.

#ifndef InstagramWifiSpoofer_h
#define InstagramWifiSpoofer_h

#import <Foundation/Foundation.h>
#import <ifaddrs.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the tri-layer Wi-Fi spoofer:
// Tier 1: Objective-C Runtime Swizzling (IGNetworkInfo, FBReachabilityAnnouncer, FNFBandwidthEstimator)
// Tier 2: SystemConfiguration & POSIX Layer (SCNetworkReachabilityGetFlags, getifaddrs)
// Tier 3: Modern Apple Transport Layer (Network.framework nw_path & nw_interface APIs)
void InstagramWifiSpoofer_Init(void);

// Returns YES if the spoofer is currently active
BOOL InstagramWifiSpoofer_IsActive(void);

// Returns YES if the underlying physical network connection is Cellular Data (WWAN)
BOOL InstagramWifiSpoofer_IsCellularData(void);

// Raw getifaddrs accessing true system network interfaces
int InstagramWifiSpoofer_GetRawIfAddrs(struct ifaddrs **ifap);

#ifdef __cplusplus
}
#endif

#endif /* InstagramWifiSpoofer_h */
