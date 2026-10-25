// InstagramReverb.m
// High-Performance Audio DSP Tweak for Instagram (com.burbn.instagram)
// Features: Real-time Pitch Shifting (-4 to +4 st) & Studio-Grade Reverb Engine
// Multi-Tier Interception via Safe Runtime Symbol Rebinding (fishhook & dyld):
//   1. CoreAudio AudioUnit Render & SetProperty (AVAudioEngine & Unit Nodes)
//   2. CoreAudio AudioQueue Enqueue Buffer with Parameters (Meta FNFPlayer)
//   3. CoreAudio AudioQueue Standard Enqueue Buffer (Direct PCM Streams)
//   4. MediaToolbox MTAudioProcessingTap (AVPlayer Video Tracks)

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <dlfcn.h>
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
    dsp->pitchPhase += (1.0f - dsp->pitchRatio) / PITCH_GRAIN_SIZE;
    if (dsp->pitchPhase >= 1.0f) dsp->pitchPhase -= 1.0f;
    else if (dsp->pitchPhase < 0.0f) dsp->pitchPhase += 1.0f;
}

// ----------------------------------------------------------------------------
// Core Sample Processor: Pitch Shift -> Freeverb Stereo Delay Network
// ----------------------------------------------------------------------------
static inline void ProcessSampleStereo(ReverbDSP *dsp, float inL, float inR, float *outL, float *outR) {
    // 1. Parameter Smoothing (Zipper-free transitions)
    const float kSmooth = 0.005f;
    dsp->roomSize += (dsp->targetRoomSize - dsp->roomSize) * kSmooth;
    dsp->wet += (dsp->targetWet - dsp->wet) * kSmooth;
    dsp->dry += (dsp->targetDry - dsp->dry) * kSmooth;

    if (fabsf(dsp->targetSemitones - dsp->semitones) > 0.001f) {
        dsp->semitones += (dsp->targetSemitones - dsp->semitones) * kSmooth;
        dsp->pitchRatio = powf(2.0f, dsp->semitones / 12.0f);
    }

    // 2. Pitch Shifter (100% tempo invariant)
    float curL = inL;
    float curR = inR;
    ProcessPitchStereo(dsp, &curL, &curR);

    // 3. Freeverb Schroeder-Moorer Delay Network
    float inputMono = (curL + curR) * 0.5f * 0.015f;
    float outCombL = 0.0f;
    float outCombR = 0.0f;

    for (int i = 0; i < COMB_COUNT; ++i) {
        outCombL += ProcessComb(&dsp->combL[i], inputMono, dsp->roomSize, dsp->damping);
        outCombR += ProcessComb(&dsp->combR[i], inputMono, dsp->roomSize, dsp->damping);
    }

    for (int i = 0; i < ALLPASS_COUNT; ++i) {
        outCombL = ProcessAllpass(&dsp->allpassL[i], outCombL);
        outCombR = ProcessAllpass(&dsp->allpassR[i], outCombR);
    }

    // 4. Complementary Dry/Wet Mixing with Soft Limiter
    *outL = SoftClip((curL * dsp->dry) + (outCombL * dsp->wet));
    *outR = SoftClip((curR * dsp->dry) + (outCombR * dsp->wet));
}

// ----------------------------------------------------------------------------
// Buffer Interceptors (Float32 & SInt16 Formats)
// ----------------------------------------------------------------------------
static void ProcessAudioBufferList(ReverbDSP *dsp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!dsp || !ioData || inNumberFrames == 0) return;

    if (ioData->mNumberBuffers >= 2) {
        // Non-interleaved stereo
        float *bufL = (float *)ioData->mBuffers[0].mData;
        float *bufR = (float *)ioData->mBuffers[1].mData;
        if (!bufL || !bufR) return;

        for (UInt32 frame = 0; frame < inNumberFrames; ++frame) {
            float outL = 0.0f, outR = 0.0f;
            ProcessSampleStereo(dsp, bufL[frame], bufR[frame], &outL, &outR);
            bufL[frame] = outL;
            bufR[frame] = outR;
        }
    } else if (ioData->mNumberBuffers == 1) {
        float *buf = (float *)ioData->mBuffers[0].mData;
        if (!buf) return;
        UInt32 channels = ioData->mBuffers[0].mNumberChannels;

        if (channels == 0 && inNumberFrames > 0) {
            channels = ioData->mBuffers[0].mDataByteSize / (inNumberFrames * sizeof(float));
        }

        if (channels >= 2) {
            for (UInt32 frame = 0; frame < inNumberFrames; ++frame) {
                UInt32 idxL = frame * channels;
                UInt32 idxR = idxL + 1;
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, buf[idxL], buf[idxR], &outL, &outR);
                buf[idxL] = outL;
                buf[idxR] = outR;
            }
        } else {
            for (UInt32 frame = 0; frame < inNumberFrames; ++frame) {
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, buf[frame], buf[frame], &outL, &outR);
                buf[frame] = (outL + outR) * 0.5f;
            }
        }
    }
}

static void ProcessRawAudioBytes(ReverbDSP *dsp, void *data, UInt32 numFrames, const AudioStreamBasicDescription *asbd) {
    if (!dsp || !data || numFrames == 0 || !asbd) return;

    if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (asbd->mChannelsPerFrame >= 2) {
            float *buf = (float *)data;
            for (UInt32 frame = 0; frame < numFrames; ++frame) {
                UInt32 idxL = frame * 2;
                UInt32 idxR = idxL + 1;
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, buf[idxL], buf[idxR], &outL, &outR);
                buf[idxL] = outL;
                buf[idxR] = outR;
            }
        } else if (asbd->mChannelsPerFrame == 1) {
            float *buf = (float *)data;
            for (UInt32 frame = 0; frame < numFrames; ++frame) {
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, buf[frame], buf[frame], &outL, &outR);
                buf[frame] = (outL + outR) * 0.5f;
            }
        }
    } else if (asbd->mBitsPerChannel == 16 && (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger)) {
        int16_t *buf = (int16_t *)data;
        if (asbd->mChannelsPerFrame >= 2) {
            for (UInt32 frame = 0; frame < numFrames; ++frame) {
                UInt32 idxL = frame * 2;
                UInt32 idxR = idxL + 1;
                float inL = (float)buf[idxL] / 32768.0f;
                float inR = (float)buf[idxR] / 32768.0f;
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, inL, inR, &outL, &outR);
                buf[idxL] = (int16_t)(SoftClip(outL) * 32767.0f);
                buf[idxR] = (int16_t)(SoftClip(outR) * 32767.0f);
            }
        } else if (asbd->mChannelsPerFrame == 1) {
            for (UInt32 frame = 0; frame < numFrames; ++frame) {
                float inMono = (float)buf[frame] / 32768.0f;
                float outL = 0.0f, outR = 0.0f;
                ProcessSampleStereo(dsp, inMono, inMono, &outL, &outR);
                buf[frame] = (int16_t)(SoftClip((outL + outR) * 0.5f) * 32767.0f);
            }
        }
    }
}

// ============================================================================
// HOOK 1: AudioUnitSetProperty & Render Callback Interception
// ============================================================================
#define MAX_WRAPPERS 32

typedef struct {
    AURenderCallback origProc;
    void *origRefCon;
} RenderCallbackWrapper;

static RenderCallbackWrapper sWrappers[MAX_WRAPPERS];
static int sWrapperCount = 0;
static pthread_mutex_t sWrapperLock = PTHREAD_MUTEX_INITIALIZER;

static OSStatus (*real_AudioUnitSetProperty)(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) = NULL;

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
                if (real_AudioUnitSetProperty) {
                    return real_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &newStruct, sizeof(newStruct));
                }
                return AudioUnitSetProperty(inUnit, inID, inScope, inElement, &newStruct, sizeof(newStruct));
            }
        }
    }
    if (real_AudioUnitSetProperty) {
        return real_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
    }
    return AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

// ============================================================================
// HOOK 2: AudioUnitRender (CoreAudio Render Interception)
// ============================================================================
static OSStatus (*real_AudioUnitRender)(AudioUnit inUnit,
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
    if (real_AudioUnitRender) {
        status = real_AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    } else {
        status = AudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    }

    if (status == noErr && ioData != NULL && inNumberFrames > 0 && g_dsp.enabled) {
        ProcessAudioBufferList(&g_dsp, inNumberFrames, ioData);
    }
    return status;
}

// ============================================================================
// HOOK 3: AudioQueue Enqueue Buffer with Parameters (Meta FNFPlayer Interception)
// ============================================================================
static OSStatus (*real_AudioQueueEnqueueBufferWithParameters)(
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    UInt32 inNumPacketDescs,
    const AudioStreamPacketDescription *inPacketDescs,
    UInt32 inImmediateModifiers,
    UInt32 inNumParamValues,
    const AudioQueueParameterEvent *inParamValues,
    const AudioTimeStamp *inStartTime,
    AudioTimeStamp *outActualStartTime
) = NULL;

static OSStatus MyAudioQueueEnqueueBufferWithParameters(
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    UInt32 inNumPacketDescs,
    const AudioStreamPacketDescription *inPacketDescs,
    UInt32 inImmediateModifiers,
    UInt32 inNumParamValues,
    const AudioQueueParameterEvent *inParamValues,
    const AudioTimeStamp *inStartTime,
    AudioTimeStamp *outActualStartTime
) {
    if (g_dsp.enabled && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0 && inNumPacketDescs == 0) {
        AudioStreamBasicDescription asbd;
        UInt32 propSize = sizeof(asbd);
        OSStatus err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_StreamDescription, &asbd, &propSize);
        if (err == noErr && asbd.mFormatID == kAudioFormatLinearPCM && asbd.mBytesPerFrame > 0) {
            UInt32 numFrames = inBuffer->mAudioDataByteSize / asbd.mBytesPerFrame;
            ProcessRawAudioBytes(&g_dsp, inBuffer->mAudioData, numFrames, &asbd);
        }
    }

    if (real_AudioQueueEnqueueBufferWithParameters) {
        return real_AudioQueueEnqueueBufferWithParameters(
            inAQ, inBuffer, inNumPacketDescs, inPacketDescs,
            inImmediateModifiers, inNumParamValues, inParamValues,
            inStartTime, outActualStartTime
        );
    }
    return AudioQueueEnqueueBufferWithParameters(
        inAQ, inBuffer, inNumPacketDescs, inPacketDescs,
        inImmediateModifiers, inNumParamValues, inParamValues,
        inStartTime, outActualStartTime
    );
}

// ============================================================================
// HOOK 4: AudioQueue Standard Enqueue Buffer (Direct PCM Streams)
// ============================================================================
static OSStatus (*real_AudioQueueEnqueueBuffer)(AudioQueueRef inAQ,
                                                AudioQueueBufferRef inBuffer,
                                                UInt32 inNumPacketDescs,
                                                const AudioStreamPacketDescription *inPacketDescs) = NULL;

static OSStatus MyAudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer,
                                          UInt32 inNumPacketDescs,
                                          const AudioStreamPacketDescription *inPacketDescs) {
    if (g_dsp.enabled && inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0 && inNumPacketDescs == 0) {
        AudioStreamBasicDescription asbd;
        UInt32 propSize = sizeof(asbd);
        OSStatus err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_StreamDescription, &asbd, &propSize);
        if (err == noErr && asbd.mFormatID == kAudioFormatLinearPCM && asbd.mBytesPerFrame > 0) {
            UInt32 numFrames = inBuffer->mAudioDataByteSize / asbd.mBytesPerFrame;
            ProcessRawAudioBytes(&g_dsp, inBuffer->mAudioData, numFrames, &asbd);
        }
    }

    if (real_AudioQueueEnqueueBuffer) {
        return real_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
    }
    return AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

// ============================================================================
// HOOK 5: MediaToolbox MTAudioProcessingTap (AVPlayer Video Track Interception)
// ============================================================================
static OSStatus (*real_MTAudioProcessingTapGetSourceAudio)(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    AudioBufferList *bufferListInOut,
    MTAudioProcessingTapFlags *flagsOut,
    CMTimeRange *timeRangeOut,
    CMItemCount *numberFramesOut
) = NULL;

static OSStatus MyMTAudioProcessingTapGetSourceAudio(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    AudioBufferList *bufferListInOut,
    MTAudioProcessingTapFlags *flagsOut,
    CMTimeRange *timeRangeOut,
    CMItemCount *numberFramesOut
) {
    OSStatus status = noErr;
    if (real_MTAudioProcessingTapGetSourceAudio) {
        status = real_MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferListInOut, flagsOut, timeRangeOut, numberFramesOut
        );
    } else {
        status = MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferListInOut, flagsOut, timeRangeOut, numberFramesOut
        );
    }

    if (status == noErr && bufferListInOut != NULL && g_dsp.enabled) {
        UInt32 frames = (numberFramesOut != NULL) ? (UInt32)*numberFramesOut : (UInt32)numberFrames;
        if (frames > 0 && bufferListInOut->mNumberBuffers > 0 && bufferListInOut->mBuffers[0].mData != NULL) {
            ProcessAudioBufferList(&g_dsp, frames, bufferListInOut);
        }
    }
    return status;
}

// ============================================================================
// DYLD_INTERPOSE Load-Time Linking Table (AudioUnit + AudioQueue + MediaToolbox)
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

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose_AudioQueueEnqueueBufferWithParameters __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)MyAudioQueueEnqueueBufferWithParameters,
    (const void *)(uintptr_t)AudioQueueEnqueueBufferWithParameters
};

__attribute__((used)) static const struct {
    const void *replacement;
    const void *replacee;
} interpose_MTAudioProcessingTapGetSourceAudio __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)MyMTAudioProcessingTapGetSourceAudio,
    (const void *)(uintptr_t)MTAudioProcessingTapGetSourceAudio
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

    // Resolve system function pointers via dlsym to guarantee zero recursion
    real_AudioUnitRender = (OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *))dlsym(RTLD_DEFAULT, "AudioUnitRender");
    real_AudioUnitSetProperty = (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32))dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    real_AudioQueueEnqueueBuffer = (OSStatus (*)(AudioQueueRef, AudioQueueBufferRef, UInt32, const AudioStreamPacketDescription *))dlsym(RTLD_DEFAULT, "AudioQueueEnqueueBuffer");
    real_AudioQueueEnqueueBufferWithParameters = (OSStatus (*)(AudioQueueRef, AudioQueueBufferRef, UInt32, const AudioStreamPacketDescription *, UInt32, UInt32, const AudioQueueParameterEvent *, const AudioTimeStamp *, AudioTimeStamp *))dlsym(RTLD_DEFAULT, "AudioQueueEnqueueBufferWithParameters");
    real_MTAudioProcessingTapGetSourceAudio = (OSStatus (*)(MTAudioProcessingTapRef, CMItemCount, AudioBufferList *, MTAudioProcessingTapFlags *, CMTimeRange *, CMItemCount *))dlsym(RTLD_DEFAULT, "MTAudioProcessingTapGetSourceAudio");

    // Runtime symbol rebinding with fishhook for AudioUnit, AudioQueue, and MediaToolbox
    struct rebinding rebindings[] = {
        {"AudioUnitRender", (void *)MyAudioUnitRender, (void **)&real_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)MyAudioUnitSetProperty, (void **)&real_AudioUnitSetProperty},
        {"AudioQueueEnqueueBuffer", (void *)MyAudioQueueEnqueueBuffer, (void **)&real_AudioQueueEnqueueBuffer},
        {"AudioQueueEnqueueBufferWithParameters", (void *)MyAudioQueueEnqueueBufferWithParameters, (void **)&real_AudioQueueEnqueueBufferWithParameters},
        {"MTAudioProcessingTapGetSourceAudio", (void *)MyMTAudioProcessingTapGetSourceAudio, (void **)&real_MTAudioProcessingTapGetSourceAudio}
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
}
