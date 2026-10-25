// InstagramReverb.h
// Public C Interface for InstagramReverb DSP Engine
// Pitch shifting (-4 to +4 st in 0.2 intervals) & studio-grade Reverb DSP

#ifndef InstagramReverb_h
#define InstagramReverb_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Master DSP Toggle
void InstagramReverb_SetEnabled(bool enabled);
bool InstagramReverb_IsEnabled(void);

// Pitch Shifter API (-4.0 to +4.0 semitones in 0.2 intervals, 0% tempo change)
void InstagramReverb_SetPitch(float semitones);
float InstagramReverb_GetPitch(void);

// Reverb Wet/Dry API (Strictly complementary: dry + wet == 1.0f)
void InstagramReverb_SetWetDry(float wet, float dry);
float InstagramReverb_GetWet(void);
float InstagramReverb_GetDry(void);

// Room Size API (0.10 to 0.98, default 0.82)
void InstagramReverb_SetRoomSize(float roomSize);
float InstagramReverb_GetRoomSize(void);

// Reset all parameters to studio defaults
void InstagramReverb_ResetDefaults(void);

#ifdef __cplusplus
}
#endif

#endif /* InstagramReverb_h */
