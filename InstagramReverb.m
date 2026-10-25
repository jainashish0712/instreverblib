// InstagramReverb.m
// High-Performance Audio DSP Tweak for Instagram (com.burbn.instagram)
// Features: Real-time Pitch Shifting (-4 to +4 st) & Studio-Grade Reverb Engine
// Dual Interception: CoreAudio AudioUnit & CoreAudio AudioQueue (Meta FNFPlayer)

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import "InstagramReverb.h"
#import "fishhook.h"

#define PITCH_BUFFER_SIZE 4096
#define PITCH_GRAIN_SIZE  2048.0f

#define COMB_COUNT 4
#define ALLPASS_COUNT 2

#define MAX_COMB_LEN 1600
#define MAX_ALLPASS_LEN 600

// Internal Comb Filter State
typedef struct {
    float buffer[MAX_COMB_LEN];
    int bufSize;
    int bufIdx;
    float filterStore;
} CombFilter;

// Internal Allpass Filter State
typedef struct {
    float buffer[MAX_ALLPASS_LEN];
    int bufSize;
    int bufIdx;
} AllpassFilter;

// Unified Reverb & Pitch DSP Engine
typedef struct {
    // Pitch Shifter Circular Buffers & State
    float pitchBufL[PITCH_BUFFER_SIZE];
    float pitchBufR[PITCH_BUFFER_SIZE];
    int pitchWriteIdx;
    float pitchPhase;

    float semitones;
    float targetSemitones;
    float pitchRatio;

    // Freeverb Delay Networks
    CombFilter combL[COMB_COUNT];
    CombFilter combR[COMB_COUNT];
    AllpassFilter allpassL[ALLPASS_COUNT];
    AllpassFilter allpassR[ALLPASS_COUNT];

    // Reverb Parameters
    float roomSize;
    float damping;
    float wet;
    float dry;

    float targetRoomSize;
    float targetWet;
    float targetDry;

    bool enabled;
    pthread_mutex_t lock;
} ReverbDSP;

static ReverbDSP g_dsp;

// Stereo delay buffer tuning lengths
static const int kCombLengthsL[COMB_COUNT] = {1116, 1188, 1277, 1356};
static const int kCombLengthsR[COMB_COUNT] = {1139, 1211, 1300, 1379};
static const int kAllpassLengthsL[ALLPASS_COUNT] = {225, 556};
static const int kAllpassLengthsR[ALLPASS_COUNT] = {248, 579};

// ----------------------------------------------------------------------------
// Fast Soft-Limiter (Prevents Digital Clipping)
// ----------------------------------------------------------------------------
static inline float SoftClip(float x) {
    if (x > 1.0f) return 1.0f;
    if (x < -1.0f) return -1.0f;
    return x - (0.10f * x * x * x);
}

// ----------------------------------------------------------------------------
// Comb & Allpass Filter Processing
// ----------------------------------------------------------------------------
static inline float ProcessComb(CombFilter *cf, float input, float feedback, float damp) {
    float output = cf->buffer[cf->bufIdx];
    cf->filterStore = (output * (1.0f - damp)) + (cf->filterStore * damp);
    cf->buffer[cf->bufIdx] = input + (cf->filterStore * feedback);
    if (++cf->bufIdx >= cf->bufSize) cf->bufIdx = 0;
    return output;
}

static inline float ProcessAllpass(AllpassFilter *af, float input) {
    float bufOut = af->buffer[af->bufIdx];
    float output = -input + bufOut;
    af->buffer[af->bufIdx] = input + (bufOut * 0.5f);
    if (++af->bufIdx >= af->bufSize) af->bufIdx = 0;
    return output;
}

// ----------------------------------------------------------------------------
// Dual-Tap Circular Buffer Pitch Shifter (100% Tempo Invariant)
// ----------------------------------------------------------------------------
static inline void ProcessPitchStereo(ReverbDSP *dsp, float *ioL, float *ioR) {
    int wIdx = dsp->pitchWriteIdx;
    dsp->pitchBufL[wIdx] = *ioL;
    dsp->pitchBufR[wIdx] = *ioR;

    if (fabsf(dsp->semitones) < 0.01f) {
        dsp->pitchWriteIdx = (wIdx + 1) % PITCH_BUFFER_SIZE;
        return;
    }

    float p1 = dsp->pitchPhase;
    float p2 = p1 + 0.5f;
    if (p2 >= 1.0f) p2 -= 1.0f;

    // Hann window crossfade
    float w1 = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * p1));
    float w2 = 1.0f - w1;

    // Tap 1
    float d1 = p1 * PITCH_GRAIN_SIZE;
    float r1 = (float)wIdx - d1;
    if (r1 < 0.0f) r1 += (float)PITCH_BUFFER_SIZE;
    int i1 = (int)r1;
    int next1 = (i1 + 1) % PITCH_BUFFER_SIZE;
    float f1 = r1 - (float)i1;
    float s1L = (1.0f - f1) * dsp->pitchBufL[i1] + f1 * dsp->pitchBufL[next1];
    float s1R = (1.0f - f1) * dsp->pitchBufR[i1] + f1 * dsp->pitchBufR[next1];

    // Tap 2
    float d2 = p2 * PITCH_GRAIN_SIZE;
    float r2 = (float)wIdx - d2;
    if (r2 < 0.0f) r2 += (float)PITCH_BUFFER_SIZE;
    int i2 = (int)r2;
    int next2 = (i2 + 1) % PITCH_BUFFER_SIZE;
    float f2 = r2 - (float)i2;
    float s2L = (1.0f - f2) * dsp->pitchBufL[i2] + f2 * dsp->pitchBufL[next2];
    float s2R = (1.0f - f2) * dsp->pitchBufR[i2] + f2 * dsp->pitchBufR[next2];

    *ioL = (s1L * w1) + (s2L * w2);
    *ioR = (s1R * w1) + (s2R * w2);

    // Advance write and phase
    dsp->pitchWriteIdx = (wIdx + 1) % PITCH_BUFFER_SIZE;
    float phaseInc = (1.0f - dsp->pitchRatio) / PITCH_GRAIN_SIZE;
    dsp->pitchPhase += phaseInc;
    if (dsp->pitchPhase >= 1.0f) dsp->pitchPhase -= 1.0f;
    if (dsp->pitchPhase < 0.0f)  dsp->pitchPhase += 1.0f;
}

// ----------------------------------------------------------------------------
// Freeverb Stereo Reverb Processing
// ----------------------------------------------------------------------------
static inline void ProcessReverbStereo(ReverbDSP *dsp, float *ioL, float *ioR) {
    float inL = *ioL;
    float inR = *ioR;
    float inputMono = (inL + inR) * 0.5f;

    float outL = 0.0f;
    float outR = 0.0f;
    float feedback = dsp->roomSize;
    float damp = dsp->damping;

    // Parallel Comb Filters
    for (int i = 0; i < COMB_COUNT; ++i) {
        outL += ProcessComb(&dsp->combL[i], inputMono, feedback, damp);
        outR += ProcessComb(&dsp->combR[i], inputMono, feedback, damp);
    }

    // Series Allpass Filters
    for (int i = 0; i < ALLPASS_COUNT; ++i) {
        outL = ProcessAllpass(&dsp->allpassL[i], outL);
        outR = ProcessAllpass(&dsp->allpassR[i], outR);
    }

    // Strictly complementary dry/wet mix + soft limiter
    *ioL = SoftClip((inL * dsp->dry) + (outL * dsp->wet));
    *ioR = SoftClip((inR * dsp->dry) + (outR * dsp->wet));
}

// ----------------------------------------------------------------------------
// Core AudioBufferList Processor (AudioUnit Pipeline)
// ----------------------------------------------------------------------------
static void ProcessAudioBufferList(ReverbDSP *dsp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!dsp->enabled || ioData == NULL || inNumberFrames == 0) return;

    AudioBuffer *b0 = &ioData->mBuffers[0];
    if (b0->mData == NULL || b0->mDataByteSize == 0) return;

    // Anti-zipper 1-pole parameter smoothing
    dsp->roomSize  += 0.05f * (dsp->targetRoomSize  - dsp->roomSize);
    dsp->wet       += 0.05f * (dsp->targetWet       - dsp->wet);
    dsp->dry       += 0.05f * (dsp->targetDry       - dsp->dry);
    dsp->semitones += 0.05f * (dsp->targetSemitones - dsp->semitones);
    dsp->pitchRatio = powf(2.0f, dsp->semitones / 12.0f);

    UInt32 channels0 = b0->mNumberChannels ? b0->mNumberChannels : 1;
    UInt32 bytesPerSample = b0->mDataByteSize / (inNumberFrames * channels0);

    // Case 1: Standard Non-Interleaved Float32 Stereo (2 distinct buffers)
    if (ioData->mNumberBuffers >= 2 && ioData->mBuffers[1].mData != NULL) {
        if (bytesPerSample == sizeof(float)) {
            float *left = (float *)ioData->mBuffers[0].mData;
            float *right = (float *)ioData->mBuffers[1].mData;
            for (UInt32 i = 0; i < inNumberFrames; i++) {
                ProcessPitchStereo(dsp, &left[i], &right[i]);
                ProcessReverbStereo(dsp, &left[i], &right[i]);
            }
        }
        return;
    }

    // Case 2: Interleaved Float32 Stereo (1 buffer, 2 interleaved channels)
    if (channels0 == 2 && bytesPerSample == sizeof(float)) {
        float *interleaved = (float *)b0->mData;
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            float *l = &interleaved[i * 2];
            float *r = &interleaved[i * 2 + 1];
            ProcessPitchStereo(dsp, l, r);
            ProcessReverbStereo(dsp, l, r);
        }
        return;
    }

    // Case 3: Interleaved Int16 Stereo
    if (channels0 == 2 && bytesPerSample == sizeof(int16_t)) {
        int16_t *interleaved = (int16_t *)b0->mData;
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            float l = (float)interleaved[i * 2] / 32768.0f;
            float r = (float)interleaved[i * 2 + 1] / 32768.0f;
            ProcessPitchStereo(dsp, &l, &r);
            ProcessReverbStereo(dsp, &l, &r);
            interleaved[i * 2]     = (int16_t)(SoftClip(l) * 32767.0f);
            interleaved[i * 2 + 1] = (int16_t)(SoftClip(r) * 32767.0f);
        }
        return;
    }

    // Case 4: Mono Float32
    if (channels0 == 1 && bytesPerSample == sizeof(float)) {
        float *samples = (float *)b0->mData;
        for (UInt32 i = 0; i < inNumberFrames; i++) {
            float l = samples[i];
            float r = samples[i];
            ProcessPitchStereo(dsp, &l, &r);
            ProcessReverbStereo(dsp, &l, &r);
            samples[i] = (l + r) * 0.5f;
        }
        return;
    }
}

// ----------------------------------------------------------------------------
// Raw PCM Audio Processor (AudioQueue Pipeline for Meta FNFPlayer)
// ----------------------------------------------------------------------------
static void ProcessRawAudioBytes(ReverbDSP *dsp, void *audioData, UInt32 numFrames, const AudioStreamBasicDescription *asbd) {
    if (!dsp->enabled || audioData == NULL || numFrames == 0 || asbd == NULL) return;

    // Anti-zipper 1-pole parameter smoothing
    dsp->roomSize  += 0.05f * (dsp->targetRoomSize  - dsp->roomSize);
    dsp->wet       += 0.05f * (dsp->targetWet       - dsp->wet);
    dsp->dry       += 0.05f * (dsp->targetDry       - dsp->dry);
    dsp->semitones += 0.05f * (dsp->targetSemitones - dsp->semitones);
    dsp->pitchRatio = powf(2.0f, dsp->semitones / 12.0f);

    UInt32 channels = asbd->mChannelsPerFrame ? asbd->mChannelsPerFrame : 2;
    bool isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bitsPerChannel = asbd->mBitsPerChannel;

    // Case A: Float32 Stereo Interleaved (Standard for modern iOS media)
    if (channels == 2 && isFloat && bitsPerChannel == 32) {
        float *samples = (float *)audioData;
        for (UInt32 i = 0; i < numFrames; i++) {
            float *l = &samples[i * 2];
            float *r = &samples[i * 2 + 1];
            ProcessPitchStereo(dsp, l, r);
            ProcessReverbStereo(dsp, l, r);
        }
        return;
    }

    // Case B: Int16 Stereo Interleaved (Common in legacy video decoders)
    if (channels == 2 && !isFloat && bitsPerChannel == 16) {
        int16_t *samples = (int16_t *)audioData;
        for (UInt32 i = 0; i < numFrames; i++) {
            float l = (float)samples[i * 2] / 32768.0f;
            float r = (float)samples[i * 2 + 1] / 32768.0f;
            ProcessPitchStereo(dsp, &l, &r);
            ProcessReverbStereo(dsp, &l, &r);
            samples[i * 2]     = (int16_t)(SoftClip(l) * 32767.0f);
            samples[i * 2 + 1] = (int16_t)(SoftClip(r) * 32767.0f);
        }
        return;
    }

    // Case C: Float32 Mono
    if (channels == 1 && isFloat && bitsPerChannel == 32) {
        float *samples = (float *)audioData;
        for (UInt32 i = 0; i < numFrames; i++) {
            float l = samples[i];
            float r = samples[i];
            ProcessPitchStereo(dsp, &l, &r);
            ProcessReverbStereo(dsp, &l, &r);
            samples[i] = (l + r) * 0.5f;
        }
        return;
    }

    // Case D: Int16 Mono
    if (channels == 1 && !isFloat && bitsPerChannel == 16) {
        int16_t *samples = (int16_t *)audioData;
        for (UInt32 i = 0; i < numFrames; i++) {
            float l = (float)samples[i] / 32768.0f;
            float r = l;
            ProcessPitchStereo(dsp, &l, &r);
            ProcessReverbStereo(dsp, &l, &r);
            samples[i] = (int16_t)(SoftClip((l + r) * 0.5f) * 32767.0f);
        }
        return;
    }
}

// ============================================================================
// HOOK 1: AudioUnitSetProperty (kAudioUnitProperty_SetRenderCallback)
// ============================================================================
typedef struct {
    AURenderCallback origProc;
    void *origRefCon;
} RenderCallbackWrapper;

#define MAX_WRAPPERS 32
static RenderCallbackWrapper sWrappers[MAX_WRAPPERS];
static int sWrapperCount = 0;
static pthread_mutex_t sWrapperLock = PTHREAD_MUTEX_INITIALIZER;

static OSStatus WrappedRenderCallback(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData) {
    RenderCallbackWrapper *w = (RenderCallbackWrapper *)inRefCon;
    OSStatus status = noErr;
    if (w && w->origProc) {
        status = w->origProc(w->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    if (status == noErr && ioData != NULL && g_dsp.enabled) {
        ProcessAudioBufferList(&g_dsp, inNumberFrames, ioData);
    }
    return status;
}

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) = NULL;

static OSStatus MyAudioUnitSetProperty(AudioUnit inUnit,
                                       AudioUnitPropertyID inID,
                                       AudioUnitScope inScope,
                                       AudioUnitElement inElement,
                                       const void *inData,
                                       UInt32 inDataSize) {
    if (inID == kAudioUnitProperty_SetRenderCallback && inData != NULL && inDataSize >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct *origStruct = (AURenderCallbackStruct *)inData;
        if (origStruct->inputProc != NULL && origStruct->inputProc != WrappedRenderCallback) {
            pthread_mutex_lock(&sWrapperLock);
            int idx = -1;
            for (int i = 0; i < sWrapperCount; i++) {
                if (sWrappers[i].origProc == origStruct->inputProc && sWrappers[i].origRefCon == origStruct->inputProcRefCon) {
                    idx = i;
                    break;
                }
            }
            if (idx == -1 && sWrapperCount < MAX_WRAPPERS) {
                idx = sWrapperCount++;
                sWrappers[idx].origProc = origStruct->inputProc;
                sWrappers[idx].origRefCon = origStruct->inputProcRefCon;
            }
            pthread_mutex_unlock(&sWrapperLock);

            if (idx >= 0) {
                AURenderCallbackStruct newStruct;
                newStruct.inputProc = WrappedRenderCallback;
                newStruct.inputProcRefCon = &sWrappers[idx];
                if (orig_AudioUnitSetProperty) {
                    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &newStruct, sizeof(newStruct));
                }
                return AudioUnitSetProperty(inUnit, inID, inScope, inElement, &newStruct, sizeof(newStruct));
            }
        }
    }
    if (orig_AudioUnitSetProperty) {
        return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
    }
    return AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

// ============================================================================
// HOOK 2: AudioUnitRender (CoreAudio Render Interception)
// ============================================================================
static OSStatus (*orig_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData) = NULL;

static OSStatus MyAudioUnitRender(AudioUnit inUnit,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inOutputBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    OSStatus status = noErr;
    if (orig_AudioUnitRender) {
        status = orig_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    } else {
        status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    }

    if (status == noErr && ioData != NULL && g_dsp.enabled) {
        ProcessAudioBufferList(&g_dsp, inNumberFrames, ioData);
    }
    return status;
}

// ============================================================================
// HOOK 3: AudioQueueEnqueueBuffer (Meta FNFPlayer / ABRAudioQueue Interception)
// ============================================================================
static OSStatus (*orig_AudioQueueEnqueueBuffer)(AudioQueueRef inAQ,
                                                AudioQueueBufferRef inBuffer,
                                                UInt32 inNumPacketDescs,
                                                const AudioStreamPacketDescription *inPacketDescs) = NULL;

static OSStatus MyAudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer,
                                          UInt32 inNumPacketDescs,
                                          const AudioStreamPacketDescription *inPacketDescs) {
    if (g_dsp.enabled && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0) {
        AudioStreamBasicDescription asbd;
        UInt32 propSize = sizeof(asbd);
        OSStatus err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_StreamDescription, &asbd, &propSize);
        if (err == noErr && asbd.mFormatID == kAudioFormatLinearPCM && asbd.mBytesPerFrame > 0) {
            UInt32 numFrames = inBuffer->mAudioDataByteSize / asbd.mBytesPerFrame;
            ProcessRawAudioBytes(&g_dsp, inBuffer->mAudioData, numFrames, &asbd);
        }
    }

    if (orig_AudioQueueEnqueueBuffer) {
        return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
    }
    return noErr;
}

// ============================================================================
// DYLD_INTERPOSE Load-Time Linking Table
// ============================================================================
#if defined(__has_feature) && __has_feature(address_sanitizer)
#else
__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose_AudioUnitRender __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)MyAudioUnitRender,
    (const void *)(uintptr_t)AudioUnitRender
};

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose_AudioUnitSetProperty __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)MyAudioUnitSetProperty,
    (const void *)(uintptr_t)AudioUnitSetProperty
};

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose_AudioQueueEnqueueBuffer __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)MyAudioQueueEnqueueBuffer,
    (const void *)(uintptr_t)AudioQueueEnqueueBuffer
};
#endif

// ============================================================================
// Public C API Implementation
// ============================================================================
void InstagramReverb_SetEnabled(bool enabled) {
    pthread_mutex_lock(&g_dsp.lock);
    g_dsp.enabled = enabled;
    pthread_mutex_unlock(&g_dsp.lock);
}

bool InstagramReverb_IsEnabled(void) {
    return g_dsp.enabled;
}

void InstagramReverb_SetPitch(float semitones) {
    pthread_mutex_lock(&g_dsp.lock);
    if (semitones < -4.0f) semitones = -4.0f;
    if (semitones > 4.0f) semitones = 4.0f;
    g_dsp.targetSemitones = semitones;
    pthread_mutex_unlock(&g_dsp.lock);
}

float InstagramReverb_GetPitch(void) {
    return g_dsp.targetSemitones;
}

void InstagramReverb_SetWetDry(float wet, float dry) {
    pthread_mutex_lock(&g_dsp.lock);
    if (wet < 0.0f) wet = 0.0f;
    if (wet > 1.0f) wet = 1.0f;
    if (dry < 0.0f) dry = 0.0f;
    if (dry > 1.0f) dry = 1.0f;
    g_dsp.targetWet = wet;
    g_dsp.targetDry = dry;
    pthread_mutex_unlock(&g_dsp.lock);
}

float InstagramReverb_GetWet(void) {
    return g_dsp.targetWet;
}

float InstagramReverb_GetDry(void) {
    return g_dsp.targetDry;
}

void InstagramReverb_SetRoomSize(float roomSize) {
    pthread_mutex_lock(&g_dsp.lock);
    if (roomSize < 0.10f) roomSize = 0.10f;
    if (roomSize > 0.98f) roomSize = 0.98f;
    g_dsp.targetRoomSize = roomSize;
    pthread_mutex_unlock(&g_dsp.lock);
}

float InstagramReverb_GetRoomSize(void) {
    return g_dsp.targetRoomSize;
}

void InstagramReverb_ResetDefaults(void) {
    InstagramReverb_SetPitch(0.0f);
    InstagramReverb_SetRoomSize(0.82f);
    InstagramReverb_SetWetDry(0.35f, 0.65f); // 65% dry / 35% wet (sum = 100%)
    InstagramReverb_SetEnabled(true);
}

// ============================================================================
// Auto-Initialization Constructor
// ============================================================================
__attribute__((constructor))
static void InstagramReverbInit(void) {
    memset(&g_dsp, 0, sizeof(ReverbDSP));
    pthread_mutex_init(&g_dsp.lock, NULL);

    // Initialize delay networks
    for (int i = 0; i < COMB_COUNT; ++i) {
        g_dsp.combL[i].bufSize = kCombLengthsL[i];
        g_dsp.combR[i].bufSize = kCombLengthsR[i];
    }
    for (int i = 0; i < ALLPASS_COUNT; ++i) {
        g_dsp.allpassL[i].bufSize = kAllpassLengthsL[i];
        g_dsp.allpassR[i].bufSize = kAllpassLengthsR[i];
    }

    g_dsp.roomSize = 0.82f;
    g_dsp.damping = 0.25f; // Fixed internal damping constant
    g_dsp.wet = 0.35f;
    g_dsp.dry = 0.65f;
    g_dsp.targetRoomSize = 0.82f;
    g_dsp.targetWet = 0.35f;
    g_dsp.targetDry = 0.65f;

    g_dsp.semitones = 0.0f;
    g_dsp.targetSemitones = 0.0f;
    g_dsp.pitchRatio = 1.0f;
    g_dsp.pitchPhase = 0.0f;
    g_dsp.pitchWriteIdx = 0;
    g_dsp.enabled = true;

    // Runtime symbol rebinding with fishhook for AudioUnit and AudioQueue
    struct rebinding rebindings[] = {
        {"AudioUnitRender", (void *)MyAudioUnitRender, (void **)&orig_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)MyAudioUnitSetProperty, (void **)&orig_AudioUnitSetProperty},
        {"AudioQueueEnqueueBuffer", (void *)MyAudioQueueEnqueueBuffer, (void **)&orig_AudioQueueEnqueueBuffer}
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
}
