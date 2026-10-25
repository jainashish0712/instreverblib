// InstagramReverb.m
// High-Performance Audio DSP Tweak for Instagram (com.burbn.instagram)
// Features: Real-time Pitch Shifting (-4 to +4 st) & Studio-Grade Reverb Engine
//
// Multi-Tier Interception Engine:
//   Tier 1: CoreAudio AudioQueue Processing Tap (Decoded PCM from Meta FNFPlayer)
//   Tier 2: Meta FNFCoreAudioWrapper Objective-C Tap Callback Swizzle
//   Tier 3: MediaToolbox MTAudioProcessingTap (AVPlayer / AVPlayerItem Video Tracks)
//   Tier 4: CoreAudio AudioUnit Render & SetProperty (AVAudioEngine & Unit Nodes)
//   Tier 5: CoreAudio AudioQueue Enqueue Buffer (Direct Uncompressed PCM Streams)
//
// Dual Rebinding Technology:
//   A. Direct GOT Scanner: Bypasses LC_DYLD_CHAINED_FIXUPS limitations in FBSharedFramework
//   B. CydiaSubstrate MSHookFunction: In-memory inline function prologue interception
//   C. fishhook: Traditional Mach-O symbol table rebinding

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <time.h>
#import "InstagramReverb.h"
#import "fishhook.h"

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

// ============================================================================
// Runtime File-Based Diagnostic Logger & Crash Reporter
// ============================================================================
static FILE *g_logFile = NULL;
static char g_logFilePath[1024] = {0};
static char g_crashFilePath[1024] = {0};
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

static void IGLog(const char *format, ...) {
    char msg[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(msg, sizeof(msg), format, args);
    va_end(args);

    // 1. Console / os_log
    NSLog(@"[InstagramReverb] %s", msg);

    // 2. Thread-safe persistent file logging
    pthread_mutex_lock(&g_logMutex);
    if (g_logFile) {
        time_t rawtime;
        struct tm *timeinfo;
        char timeBuf[32];
        time(&rawtime);
        timeinfo = localtime(&rawtime);
        strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", timeinfo);
        fprintf(g_logFile, "[%s] %s\n", timeBuf, msg);
        fflush(g_logFile);
    }
    pthread_mutex_unlock(&g_logMutex);
}

// POSIX Signal Handler for hardware faults
static void SignalCrashHandler(int sig, siginfo_t *info, void *context) {
    const char *sigName = (sig == SIGSEGV) ? "SIGSEGV (Segmentation Fault)" :
                          (sig == SIGBUS)  ? "SIGBUS (Bus Error / Bad Memory Access)" :
                          (sig == SIGABRT) ? "SIGABRT (Abort / Assertion Failure)" :
                          (sig == SIGILL)  ? "SIGILL (Illegal Instruction)" : "UNKNOWN SIGNAL";

    int fd = open(g_crashFilePath[0] ? g_crashFilePath : "/tmp/InstagramReverb_crash.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        time_t rawtime;
        time(&rawtime);
        char header[512];
        int hlen = snprintf(header, sizeof(header),
            "\n==================================================================\n"
            "FATAL CRASH TRAPPED BY INSTAGRAM REVERB\n"
            "Timestamp: %ld\n"
            "Signal: %d -> %s\n"
            "Fault Address: %p\n"
            "Thread: %p\n"
            "------------------------------------------------------------------\n"
            "Backtrace Frames:\n",
            (long)rawtime, sig, sigName, info ? info->si_addr : NULL, (void *)pthread_self());
        write(fd, header, hlen);

        void *callstack[64];
        int frames = backtrace(callstack, 64);
        char **symbols = backtrace_symbols(callstack, frames);
        if (symbols) {
            for (int i = 0; i < frames; ++i) {
                char frameBuf[512];
                int flen = snprintf(frameBuf, sizeof(frameBuf), "  [%02d] %s\n", i, symbols[i]);
                write(fd, frameBuf, flen);
            }
            free(symbols);
        }
        write(fd, "==================================================================\n", 67);
        fsync(fd);
        close(fd);
    }

    signal(sig, SIG_DFL);
}

static void UncaughtExceptionHandler(NSException *exception) {
    IGLog("[CRASH] Uncaught NSException: %s Reason: %s",
          [exception.name UTF8String] ?: "Unknown",
          [exception.reason UTF8String] ?: "None");
    NSArray *stack = [exception callStackSymbols];
    for (NSString *frame in stack) {
        IGLog("  %s", [frame UTF8String]);
    }
}

// ============================================================================
// DSP Architecture: Schroeder-Moorer Reverb + Time-Domain Pitch Shifter
// ============================================================================
#define COMB_COUNT 4
#define ALLPASS_COUNT 2
#define PITCH_BUF_SIZE 4096
#define PITCH_BUF_MASK (PITCH_BUF_SIZE - 1)

static const int kCombLengthsL[COMB_COUNT] = {1116, 1188, 1277, 1356};
static const int kCombLengthsR[COMB_COUNT] = {1139, 1211, 1300, 1379};
static const int kAllpassLengthsL[ALLPASS_COUNT] = {556, 441};
static const int kAllpassLengthsR[ALLPASS_COUNT] = {579, 464};

typedef struct {
    float buffer[1600];
    int bufSize;
    int bufIdx;
    float store;
} CombFilter;

typedef struct {
    float buffer[600];
    int bufSize;
    int bufIdx;
} AllpassFilter;

typedef struct {
    pthread_mutex_t lock;

    CombFilter combL[COMB_COUNT];
    CombFilter combR[COMB_COUNT];
    AllpassFilter allpassL[ALLPASS_COUNT];
    AllpassFilter allpassR[ALLPASS_COUNT];

    // Pitch Shifter state
    float pitchBufL[PITCH_BUF_SIZE];
    float pitchBufR[PITCH_BUF_SIZE];
    int pitchWriteIdx;
    float pitchPhase;

    float semitones;
    float targetSemitones;
    float pitchRatio;

    // Reverb parameters
    float roomSize;
    float damping;
    float wet;
    float dry;

    float targetRoomSize;
    float targetWet;
    float targetDry;

    bool enabled;
} ReverbDSP;

static ReverbDSP g_dsp;

static inline float SoftClip(float x) {
    if (x > 3.0f) return 1.0f;
    if (x < -3.0f) return -1.0f;
    return x * (27.0f + x * x) / (27.0f + 9.0f * x * x);
}

static inline float ProcessComb(CombFilter *cf, float input, float feedback, float damp) {
    float output = cf->buffer[cf->bufIdx];
    cf->store = (output * (1.0f - damp)) + (cf->store * damp);
    cf->buffer[cf->bufIdx] = input + (cf->store * feedback);
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

static inline void ProcessSampleStereo(ReverbDSP *dsp, float inL, float inR, float *outL, float *outR) {
    // 1. Parameter Smoothing (Anti-zipper filter)
    dsp->roomSize += 0.005f * (dsp->targetRoomSize - dsp->roomSize);
    dsp->wet += 0.005f * (dsp->targetWet - dsp->wet);
    dsp->dry += 0.005f * (dsp->targetDry - dsp->dry);

    if (dsp->targetSemitones != dsp->semitones) {
        dsp->semitones += 0.01f * (dsp->targetSemitones - dsp->semitones);
        dsp->pitchRatio = powf(2.0f, dsp->semitones / 12.0f);
    }

    // 2. Pitch Shifter (Dual dual-head overlapping windowed delay)
    float pInL = inL;
    float pInR = inR;

    if (fabsf(dsp->semitones) > 0.01f) {
        dsp->pitchBufL[dsp->pitchWriteIdx] = inL;
        dsp->pitchBufR[dsp->pitchWriteIdx] = inR;

        float windowSize = 2048.0f;
        float halfWindow = windowSize * 0.5f;

        float off0 = dsp->pitchPhase;
        float off1 = dsp->pitchPhase + halfWindow;
        if (off1 >= windowSize) off1 -= windowSize;

        float w0 = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * off0 / windowSize));
        float w1 = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * off1 / windowSize));

        float readIdx0 = (float)dsp->pitchWriteIdx - off0;
        float readIdx1 = (float)dsp->pitchWriteIdx - off1;

        while (readIdx0 < 0.0f) readIdx0 += (float)PITCH_BUF_SIZE;
        while (readIdx1 < 0.0f) readIdx1 += (float)PITCH_BUF_SIZE;

        int i0_0 = (int)readIdx0 & PITCH_BUF_MASK;
        int i0_1 = (i0_0 + 1) & PITCH_BUF_MASK;
        float frac0 = readIdx0 - (float)((int)readIdx0);

        int i1_0 = (int)readIdx1 & PITCH_BUF_MASK;
        int i1_1 = (i1_0 + 1) & PITCH_BUF_MASK;
        float frac1 = readIdx1 - (float)((int)readIdx1);

        float sL0 = dsp->pitchBufL[i0_0] + frac0 * (dsp->pitchBufL[i0_1] - dsp->pitchBufL[i0_0]);
        float sR0 = dsp->pitchBufR[i0_0] + frac0 * (dsp->pitchBufR[i0_1] - dsp->pitchBufR[i0_0]);

        float sL1 = dsp->pitchBufL[i1_0] + frac1 * (dsp->pitchBufL[i1_1] - dsp->pitchBufL[i1_0]);
        float sR1 = dsp->pitchBufR[i1_0] + frac1 * (dsp->pitchBufR[i1_1] - dsp->pitchBufR[i1_0]);

        pInL = (sL0 * w0) + (sL1 * w1);
        pInR = (sR0 * w0) + (sR1 * w1);

        dsp->pitchPhase += (1.0f - dsp->pitchRatio);
        while (dsp->pitchPhase >= windowSize) dsp->pitchPhase -= windowSize;
        while (dsp->pitchPhase < 0.0f) dsp->pitchPhase += windowSize;

        dsp->pitchWriteIdx = (dsp->pitchWriteIdx + 1) & PITCH_BUF_MASK;
    }

    // 3. Parallel Comb Filters
    float combSumL = 0.0f;
    float combSumR = 0.0f;
    for (int i = 0; i < COMB_COUNT; ++i) {
        combSumL += ProcessComb(&dsp->combL[i], pInL, dsp->roomSize, dsp->damping);
        combSumR += ProcessComb(&dsp->combR[i], pInR, dsp->roomSize, dsp->damping);
    }

    // 4. Series Allpass Filters
    float revL = combSumL;
    float revR = combSumR;
    for (int i = 0; i < ALLPASS_COUNT; ++i) {
        revL = ProcessAllpass(&dsp->allpassL[i], revL);
        revR = ProcessAllpass(&dsp->allpassR[i], revR);
    }

    // 5. Cross-stereo diffusion & Wet/Dry mix with soft clipping
    float wetL = (revL * 0.85f) + (revR * 0.15f);
    float wetR = (revR * 0.85f) + (revL * 0.15f);

    *outL = SoftClip((pInL * dsp->dry) + (wetL * dsp->wet));
    *outR = SoftClip((pInR * dsp->dry) + (wetR * dsp->wet));
}

static inline void ProcessAudioBufferList(ReverbDSP *dsp, UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!dsp || !ioData || inNumberFrames == 0 || !dsp->enabled) return;

    if (ioData->mNumberBuffers >= 2) {
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

static inline void ProcessRawAudioBytes(ReverbDSP *dsp, void *data, UInt32 numFrames, const AudioStreamBasicDescription *asbd) {
    if (!dsp || !data || numFrames == 0 || !asbd || !dsp->enabled) return;

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
// Forward Function Pointer Declarations
// ============================================================================
static OSStatus (*real_AudioUnitSetProperty)(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) = NULL;

static OSStatus (*real_AudioUnitRender)(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData) = NULL;

static OSStatus (*real_AudioQueueStart)(AudioQueueRef inAQ, const AudioTimeStamp *inStartTime) = NULL;
static OSStatus (*real_AudioQueueDispose)(AudioQueueRef inAQ, Boolean inImmediate) = NULL;

static OSStatus (*real_AudioQueueEnqueueBuffer)(AudioQueueRef inAQ,
                                                AudioQueueBufferRef inBuffer,
                                                UInt32 inNumPacketDescs,
                                                const AudioStreamPacketDescription *inPacketDescs) = NULL;

static OSStatus (*real_AudioQueueEnqueueBufferWithParameters)(
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    UInt32 inNumPacketDescs,
    const AudioStreamPacketDescription *inPacketDescs,
    UInt32 inTrimFramesAtStart,
    UInt32 inTrimFramesAtEnd,
    UInt32 inNumParamValues,
    const AudioQueueParameterEvent *inParamValues,
    const AudioTimeStamp *inStartTime,
    AudioTimeStamp *outActualStartTime
) = NULL;

static OSStatus (*real_AudioQueueProcessingTapNew)(
    AudioQueueRef inAQ,
    AudioQueueProcessingTapCallback inCallback,
    void *inClientData,
    AudioQueueProcessingTapFlags inFlags,
    UInt32 *outMaxFrames,
    AudioStreamBasicDescription *outProcessingFormat,
    AudioQueueProcessingTapRef *outAQTap
) = NULL;

static OSStatus (*real_AudioQueueProcessingTapGetSourceAudio)(
    AudioQueueProcessingTapRef inAQTap,
    UInt32 inNumberFrames,
    AudioTimeStamp *ioTimeStamp,
    AudioQueueProcessingTapFlags *outFlags,
    UInt32 *outNumberFrames,
    AudioBufferList *ioData
) = NULL;

static OSStatus (*real_MTAudioProcessingTapGetSourceAudio)(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    AudioBufferList *bufferListInOut,
    MTAudioProcessingTapFlags *flagsOut,
    CMTimeRange *timeRangeOut,
    CMItemCount *numberFramesOut
) = NULL;

// ============================================================================
// TIER 1: CoreAudio AudioQueue Processing Tap Engine (Decoded PCM Interception)
// ============================================================================
#define MAX_TRACKED_AQS 64

typedef struct {
    AudioQueueRef aq;
    AudioQueueProcessingTapRef tap;
    AudioQueueProcessingTapCallback origCallback;
    void *origClientData;
    AudioStreamBasicDescription format;
    bool active;
} TrackedAQ;

static TrackedAQ g_trackedAQs[MAX_TRACKED_AQS];
static pthread_mutex_t g_aqMutex = PTHREAD_MUTEX_INITIALIZER;

static void MyAudioQueueProcessingTapCallback(
    void *inClientData,
    AudioQueueProcessingTapRef inAQTap,
    UInt32 inNumberFrames,
    AudioTimeStamp *ioTimeStamp,
    AudioQueueProcessingTapFlags *ioFlags,
    UInt32 *outNumberFrames,
    AudioBufferList *ioData
) {
    if (!inAQTap || !ioData) return;

    AudioQueueProcessingTapCallback origCb = NULL;
    void *origClient = NULL;

    pthread_mutex_lock(&g_aqMutex);
    for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
        if (g_trackedAQs[i].active && g_trackedAQs[i].tap == inAQTap) {
            origCb = g_trackedAQs[i].origCallback;
            origClient = g_trackedAQs[i].origClientData;
            break;
        }
    }
    pthread_mutex_unlock(&g_aqMutex);

    if (origCb) {
        origCb(origClient, inAQTap, inNumberFrames, ioTimeStamp, ioFlags, outNumberFrames, ioData);
    } else {
        if (real_AudioQueueProcessingTapGetSourceAudio) {
            real_AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, ioFlags, outNumberFrames, ioData);
        } else {
            AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, ioFlags, outNumberFrames, ioData);
        }
    }

    if (ioData != NULL && outNumberFrames != NULL && *outNumberFrames > 0 && g_dsp.enabled) {
        static uint32_t s_tapFramesCount = 0;
        if (s_tapFramesCount < 10) {
            s_tapFramesCount++;
            IGLog("[AQ Tap Callback] Rendered %u frames, bufs=%u, data0=%p",
                  (unsigned int)*outNumberFrames, (unsigned int)ioData->mNumberBuffers,
                  (ioData->mNumberBuffers > 0) ? ioData->mBuffers[0].mData : NULL);
        }
        ProcessAudioBufferList(&g_dsp, *outNumberFrames, ioData);
    }
}

static void EnsureAudioQueueTapped(AudioQueueRef inAQ) {
    if (!inAQ) return;

    pthread_mutex_lock(&g_aqMutex);
    for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
        if (g_trackedAQs[i].active && g_trackedAQs[i].aq == inAQ) {
            pthread_mutex_unlock(&g_aqMutex);
            return; // Already tapped
        }
    }
    pthread_mutex_unlock(&g_aqMutex);

    UInt32 maxFrames = 0;
    AudioStreamBasicDescription processingFormat;
    memset(&processingFormat, 0, sizeof(processingFormat));
    AudioQueueProcessingTapRef tap = NULL;

    OSStatus err = noErr;
    if (real_AudioQueueProcessingTapNew) {
        err = real_AudioQueueProcessingTapNew(
            inAQ,
            MyAudioQueueProcessingTapCallback,
            (void *)inAQ,
            kAudioQueueProcessingTap_PreEffects,
            &maxFrames,
            &processingFormat,
            &tap
        );
    } else {
        err = AudioQueueProcessingTapNew(
            inAQ,
            MyAudioQueueProcessingTapCallback,
            (void *)inAQ,
            kAudioQueueProcessingTap_PreEffects,
            &maxFrames,
            &processingFormat,
            &tap
        );
    }

    IGLog("[AudioQueue] AudioQueueProcessingTapNew on AQ=%p -> err=%d, tap=%p, maxFrames=%u, rate=%.1f, ch=%u",
          inAQ, (int)err, tap, (unsigned int)maxFrames, processingFormat.mSampleRate, (unsigned int)processingFormat.mChannelsPerFrame);

    if (err == noErr && tap != NULL) {
        pthread_mutex_lock(&g_aqMutex);
        for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
            if (!g_trackedAQs[i].active) {
                g_trackedAQs[i].aq = inAQ;
                g_trackedAQs[i].tap = tap;
                g_trackedAQs[i].origCallback = NULL;
                g_trackedAQs[i].origClientData = NULL;
                g_trackedAQs[i].format = processingFormat;
                g_trackedAQs[i].active = true;
                break;
            }
        }
        pthread_mutex_unlock(&g_aqMutex);
    }
}

static OSStatus MyAudioQueueStart(AudioQueueRef inAQ, const AudioTimeStamp *inStartTime) {
    static uint32_t s_aqStartCount = 0;
    if (s_aqStartCount < 20) {
        s_aqStartCount++;
        IGLog("[Hook] AudioQueueStart [#%u]: AQ=%p", s_aqStartCount, inAQ);
    }

    if (inAQ) {
        EnsureAudioQueueTapped(inAQ);
    }

    if (real_AudioQueueStart) {
        return real_AudioQueueStart(inAQ, inStartTime);
    }
    return AudioQueueStart(inAQ, inStartTime);
}

static OSStatus MyAudioQueueDispose(AudioQueueRef inAQ, Boolean inImmediate) {
    if (inAQ) {
        pthread_mutex_lock(&g_aqMutex);
        for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
            if (g_trackedAQs[i].active && g_trackedAQs[i].aq == inAQ) {
                if (g_trackedAQs[i].tap) {
                    AudioQueueProcessingTapDispose(g_trackedAQs[i].tap);
                }
                memset(&g_trackedAQs[i], 0, sizeof(TrackedAQ));
                break;
            }
        }
        pthread_mutex_unlock(&g_aqMutex);
    }

    if (real_AudioQueueDispose) {
        return real_AudioQueueDispose(inAQ, inImmediate);
    }
    return AudioQueueDispose(inAQ, inImmediate);
}

static OSStatus MyAudioQueueProcessingTapNew(
    AudioQueueRef inAQ,
    AudioQueueProcessingTapCallback inCallback,
    void *inClientData,
    AudioQueueProcessingTapFlags inFlags,
    UInt32 *outMaxFrames,
    AudioStreamBasicDescription *outProcessingFormat,
    AudioQueueProcessingTapRef *outAQTap
) {
    IGLog("[Hook] AudioQueueProcessingTapNew called by app for AQ=%p, origCb=%p", inAQ, inCallback);

    AudioQueueProcessingTapRef tap = NULL;
    OSStatus err = noErr;

    if (real_AudioQueueProcessingTapNew) {
        err = real_AudioQueueProcessingTapNew(
            inAQ,
            MyAudioQueueProcessingTapCallback,
            (void *)inAQ,
            inFlags,
            outMaxFrames,
            outProcessingFormat,
            &tap
        );
    } else {
        err = AudioQueueProcessingTapNew(
            inAQ,
            MyAudioQueueProcessingTapCallback,
            (void *)inAQ,
            inFlags,
            outMaxFrames,
            outProcessingFormat,
            &tap
        );
    }

    if (err == noErr && tap != NULL) {
        if (outAQTap) *outAQTap = tap;

        pthread_mutex_lock(&g_aqMutex);
        int targetIdx = -1;
        for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
            if (g_trackedAQs[i].active && g_trackedAQs[i].aq == inAQ) {
                targetIdx = i;
                break;
            }
        }
        if (targetIdx == -1) {
            for (int i = 0; i < MAX_TRACKED_AQS; ++i) {
                if (!g_trackedAQs[i].active) {
                    targetIdx = i;
                    break;
                }
            }
        }
        if (targetIdx >= 0) {
            g_trackedAQs[targetIdx].aq = inAQ;
            g_trackedAQs[targetIdx].tap = tap;
            g_trackedAQs[targetIdx].origCallback = inCallback;
            g_trackedAQs[targetIdx].origClientData = inClientData;
            if (outProcessingFormat) g_trackedAQs[targetIdx].format = *outProcessingFormat;
            g_trackedAQs[targetIdx].active = true;
        }
        pthread_mutex_unlock(&g_aqMutex);
    }
    return err;
}

static OSStatus MyAudioQueueProcessingTapGetSourceAudio(
    AudioQueueProcessingTapRef inAQTap,
    UInt32 inNumberFrames,
    AudioTimeStamp *ioTimeStamp,
    AudioQueueProcessingTapFlags *outFlags,
    UInt32 *outNumberFrames,
    AudioBufferList *ioData
) {
    OSStatus status = noErr;
    if (real_AudioQueueProcessingTapGetSourceAudio) {
        status = real_AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, outFlags, outNumberFrames, ioData);
    } else {
        status = AudioQueueProcessingTapGetSourceAudio(inAQTap, inNumberFrames, ioTimeStamp, outFlags, outNumberFrames, ioData);
    }

    if (status == noErr && ioData != NULL && outNumberFrames != NULL && *outNumberFrames > 0 && g_dsp.enabled) {
        ProcessAudioBufferList(&g_dsp, *outNumberFrames, ioData);
    }
    return status;
}

// ============================================================================
// TIER 2: Meta FNFCoreAudioWrapper Objective-C Method Swizzle
// ============================================================================
static void (*orig_FNF_tapCallback)(id, SEL, AudioQueueProcessingTapRef, UInt32, AudioBufferList *, UInt32) = NULL;

static void swizzled_FNF_tapCallback(id self, SEL _cmd, AudioQueueProcessingTapRef tap, UInt32 sourceFlags, AudioBufferList *ioData, UInt32 numFrames) {
    if (orig_FNF_tapCallback) {
        orig_FNF_tapCallback(self, _cmd, tap, sourceFlags, ioData, numFrames);
    }
    if (g_dsp.enabled && ioData != NULL && numFrames > 0) {
        ProcessAudioBufferList(&g_dsp, numFrames, ioData);
    }
}

static void InitFNFObjCSwizzling(void) {
    Class clsFNF = objc_getClass("FNFCoreAudioWrapper");
    if (clsFNF) {
        SEL selTap = sel_registerName("audioQueueConverterProcessingTapCallback:sourceFlags:ioData:numFrames:");
        Method m = class_getInstanceMethod(clsFNF, selTap);
        if (m) {
            orig_FNF_tapCallback = (void (*)(id, SEL, AudioQueueProcessingTapRef, UInt32, AudioBufferList *, UInt32))method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_FNF_tapCallback);
            IGLog("[Swizzle] Hooked FNFCoreAudioWrapper audioQueueConverterProcessingTapCallback!");
        }
    }
}

// ============================================================================
// TIER 3: MediaToolbox MTAudioProcessingTap (AVPlayer Video Track Interception)
// ============================================================================
static void MyMTAudioProcessingTapProcessCallback(
    MTAudioProcessingTapRef tap,
    CMItemCount numberFrames,
    MTAudioProcessingTapFlags flags,
    AudioBufferList *bufferListInOut,
    CMItemCount *numberFramesOut,
    MTAudioProcessingTapFlags *flagsOut
) {
    OSStatus err = noErr;
    if (real_MTAudioProcessingTapGetSourceAudio) {
        err = real_MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    } else {
        err = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    }

    if (err == noErr && bufferListInOut != NULL && g_dsp.enabled) {
        CMItemCount frames = (numberFramesOut != NULL) ? *numberFramesOut : numberFrames;
        if (frames > 0 && bufferListInOut->mNumberBuffers > 0 && bufferListInOut->mBuffers[0].mData != NULL) {
            ProcessAudioBufferList(&g_dsp, (UInt32)frames, bufferListInOut);
        }
    }
}

static void AttachAudioMixToPlayerItem(AVPlayerItem *item) {
    if (!item || item.audioMix) return;

    AVAsset *asset = item.asset;
    if (!asset) return;

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) return;

    MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = 0;
    callbacks.process = MyMTAudioProcessingTapProcessCallback;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    if (err == noErr && tap != NULL) {
        NSMutableArray *inputParams = [NSMutableArray array];
        for (AVAssetTrack *track in tracks) {
            AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
            params.audioTapProcessor = tap;
            [inputParams addObject:params];
        }
        AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
        audioMix.inputParameters = inputParams;
        item.audioMix = audioMix;
        CFRelease(tap);
        IGLog("[AVPlayerItem] Successfully attached MTAudioProcessingTap audioMix to %p", item);
    }
}

static id (*orig_AVPlayerItem_initWithAsset)(id, SEL, AVAsset *, NSArray *) = NULL;
static id swizzled_AVPlayerItem_initWithAsset(id self, SEL _cmd, AVAsset *asset, NSArray *keys) {
    id item = orig_AVPlayerItem_initWithAsset(self, _cmd, asset, keys);
    if (item) {
        AttachAudioMixToPlayerItem(item);
    }
    return item;
}

static id (*orig_AVPlayerItem_initWithURL)(id, SEL, NSURL *) = NULL;
static id swizzled_AVPlayerItem_initWithURL(id self, SEL _cmd, NSURL *URL) {
    id item = orig_AVPlayerItem_initWithURL(self, _cmd, URL);
    if (item) {
        AttachAudioMixToPlayerItem(item);
    }
    return item;
}

static void InitAVPlayerItemSwizzling(void) {
    Class clsItem = objc_getClass("AVPlayerItem");
    if (clsItem) {
        SEL selAsset = @selector(initWithAsset:automaticallyLoadedAssetKeys:);
        Method mAsset = class_getInstanceMethod(clsItem, selAsset);
        if (mAsset) {
            orig_AVPlayerItem_initWithAsset = (id (*)(id, SEL, AVAsset *, NSArray *))method_getImplementation(mAsset);
            method_setImplementation(mAsset, (IMP)swizzled_AVPlayerItem_initWithAsset);
            IGLog("[Swizzle] Hooked AVPlayerItem initWithAsset:automaticallyLoadedAssetKeys:!");
        }

        SEL selURL = @selector(initWithURL:);
        Method mURL = class_getInstanceMethod(clsItem, selURL);
        if (mURL) {
            orig_AVPlayerItem_initWithURL = (id (*)(id, SEL, NSURL *))method_getImplementation(mURL);
            method_setImplementation(mURL, (IMP)swizzled_AVPlayerItem_initWithURL);
            IGLog("[Swizzle] Hooked AVPlayerItem initWithURL:!");
        }
    }
}

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
// TIER 4: CoreAudio AudioUnit Render & SetProperty Interception
// ============================================================================
#define MAX_WRAPPERS 32
typedef struct {
    AURenderCallback origProc;
    void *origRefCon;
} RenderCallbackWrapper;

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
    if (status == noErr && ioData != NULL && inNumberFrames > 0 && g_dsp.enabled) {
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
                IGLog("[Hook] AudioUnitSetProperty: Hooked AURenderCallback on unit %p (idx=%d)", inUnit, idx);
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
// TIER 5: CoreAudio AudioQueue Enqueue Buffer Interception (Direct PCM Streams)
// ============================================================================
static OSStatus MyAudioQueueEnqueueBufferWithParameters(
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    UInt32 inNumPacketDescs,
    const AudioStreamPacketDescription *inPacketDescs,
    UInt32 inTrimFramesAtStart,
    UInt32 inTrimFramesAtEnd,
    UInt32 inNumParamValues,
    const AudioQueueParameterEvent *inParamValues,
    const AudioTimeStamp *inStartTime,
    AudioTimeStamp *outActualStartTime
) {
    if (inAQ) {
        EnsureAudioQueueTapped(inAQ);
    }

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
            inTrimFramesAtStart, inTrimFramesAtEnd, inNumParamValues, inParamValues,
            inStartTime, outActualStartTime
        );
    }
    return AudioQueueEnqueueBufferWithParameters(
        inAQ, inBuffer, inNumPacketDescs, inPacketDescs,
        inTrimFramesAtStart, inTrimFramesAtEnd, inNumParamValues, inParamValues,
        inStartTime, outActualStartTime
    );
}

static OSStatus MyAudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer,
                                          UInt32 inNumPacketDescs,
                                          const AudioStreamPacketDescription *inPacketDescs) {
    if (inAQ) {
        EnsureAudioQueueTapped(inAQ);
    }

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
// DUAL REBINDING TECHNOLOGY
// Method A: Direct GOT Scanner (Overcomes LC_DYLD_CHAINED_FIXUPS in FBSharedFramework)
// Method B: CydiaSubstrate MSHookFunction Dynamic Linking
// ============================================================================
typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
static MSHookFunction_t g_MSHookFunction = NULL;

static void PatchGOTPointersInAllImages(void *target_func, void *replacement_func, const char *symbol_name) {
    if (!target_func || !replacement_func) return;

    uintptr_t target_addr = (uintptr_t)target_func & 0x0000007fffffffffULL;
    uintptr_t repl_addr = (uintptr_t)replacement_func;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const char *image_name = _dyld_get_image_name(i);
        if (!header || !image_name) continue;

        // Target Instagram, FBSharedFramework, and local app frameworks
        if (!strstr(image_name, "Instagram.app") &&
            !strstr(image_name, "FBSharedFramework") &&
            !strstr(image_name, "Instagram")) {
            continue;
        }

        uintptr_t cur = (uintptr_t)header;
        #ifdef __LP64__
        cur += sizeof(struct mach_header_64);
        #else
        cur += sizeof(struct mach_header);
        #endif

        for (uint32_t c = 0; c < header->ncmds; c++) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cur;
            if (seg->cmd == LC_SEGMENT_64) {
                const char *segname = seg->segname;
                if (strcmp(segname, "__DATA_CONST") == 0 ||
                    strcmp(segname, "__DATA") == 0 ||
                    strcmp(segname, "__AUTH_CONST") == 0) {

                    struct section_64 *sect = (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64));
                    for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                        const char *sectname = sect->sectname;
                        if (strcmp(sectname, "__got") == 0 ||
                            strcmp(sectname, "__auth_got") == 0 ||
                            strcmp(sectname, "__nl_symbol_ptr") == 0 ||
                            strcmp(sectname, "__la_symbol_ptr") == 0) {

                            uintptr_t sect_addr = (uintptr_t)slide + sect->addr;
                            size_t sect_size = (size_t)sect->size;
                            uintptr_t *slots = (uintptr_t *)sect_addr;
                            size_t num_slots = sect_size / sizeof(uintptr_t);

                            for (size_t k = 0; k < num_slots; k++) {
                                uintptr_t val = slots[k] & 0x0000007fffffffffULL;
                                if (val == target_addr) {
                                    vm_address_t page = (vm_address_t)&slots[k];
                                    kern_return_t kr = vm_protect(mach_task_self(), page, sizeof(uintptr_t), false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                                    if (kr == KERN_SUCCESS) {
                                        slots[k] = repl_addr;
                                        IGLog("[GOT Scanner] Patched %s in %s at %p", symbol_name, sectname, &slots[k]);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cur += seg->cmdsize;
        }
    }
}

static void InstallAllInterceptionHooks(void) {
    // 1. Resolve CydiaSubstrate MSHookFunction if present
    g_MSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!g_MSHookFunction) {
        void *h = dlopen("@rpath/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            h = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW | RTLD_GLOBAL);
        }
        if (h) {
            g_MSHookFunction = (MSHookFunction_t)dlsym(h, "MSHookFunction");
        }
    }

    if (g_MSHookFunction) {
        IGLog("[Substrate] MSHookFunction available! Intercepting via inline prologue hooks...");
        g_MSHookFunction((void *)AudioQueueStart, (void *)MyAudioQueueStart, (void **)&real_AudioQueueStart);
        g_MSHookFunction((void *)AudioQueueDispose, (void *)MyAudioQueueDispose, (void **)&real_AudioQueueDispose);
        g_MSHookFunction((void *)AudioQueueProcessingTapNew, (void *)MyAudioQueueProcessingTapNew, (void **)&real_AudioQueueProcessingTapNew);
        g_MSHookFunction((void *)AudioQueueProcessingTapGetSourceAudio, (void *)MyAudioQueueProcessingTapGetSourceAudio, (void **)&real_AudioQueueProcessingTapGetSourceAudio);
        g_MSHookFunction((void *)AudioUnitRender, (void *)MyAudioUnitRender, (void **)&real_AudioUnitRender);
        g_MSHookFunction((void *)AudioUnitSetProperty, (void *)MyAudioUnitSetProperty, (void **)&real_AudioUnitSetProperty);
        g_MSHookFunction((void *)AudioQueueEnqueueBuffer, (void *)MyAudioQueueEnqueueBuffer, (void **)&real_AudioQueueEnqueueBuffer);
        g_MSHookFunction((void *)AudioQueueEnqueueBufferWithParameters, (void *)MyAudioQueueEnqueueBufferWithParameters, (void **)&real_AudioQueueEnqueueBufferWithParameters);
        g_MSHookFunction((void *)MTAudioProcessingTapGetSourceAudio, (void *)MyMTAudioProcessingTapGetSourceAudio, (void **)&real_MTAudioProcessingTapGetSourceAudio);
    }

    // 2. Direct GOT Scanner (Crucial for FBSharedFramework chained fixups)
    IGLog("[GOT Scanner] Scanning GOT entries across all loaded images...");
    PatchGOTPointersInAllImages((void *)AudioQueueStart, (void *)MyAudioQueueStart, "AudioQueueStart");
    PatchGOTPointersInAllImages((void *)AudioQueueDispose, (void *)MyAudioQueueDispose, "AudioQueueDispose");
    PatchGOTPointersInAllImages((void *)AudioQueueProcessingTapNew, (void *)MyAudioQueueProcessingTapNew, "AudioQueueProcessingTapNew");
    PatchGOTPointersInAllImages((void *)AudioQueueProcessingTapGetSourceAudio, (void *)MyAudioQueueProcessingTapGetSourceAudio, "AudioQueueProcessingTapGetSourceAudio");
    PatchGOTPointersInAllImages((void *)AudioUnitRender, (void *)MyAudioUnitRender, "AudioUnitRender");
    PatchGOTPointersInAllImages((void *)AudioUnitSetProperty, (void *)MyAudioUnitSetProperty, "AudioUnitSetProperty");
    PatchGOTPointersInAllImages((void *)AudioQueueEnqueueBuffer, (void *)MyAudioQueueEnqueueBuffer, "AudioQueueEnqueueBuffer");
    PatchGOTPointersInAllImages((void *)AudioQueueEnqueueBufferWithParameters, (void *)MyAudioQueueEnqueueBufferWithParameters, "AudioQueueEnqueueBufferWithParameters");
    PatchGOTPointersInAllImages((void *)MTAudioProcessingTapGetSourceAudio, (void *)MyMTAudioProcessingTapGetSourceAudio, "MTAudioProcessingTapGetSourceAudio");

    // 3. Classic fishhook for images with traditional indirect symbol tables
    struct rebinding rebindings[] = {
        {"AudioQueueStart", (void *)MyAudioQueueStart, (void **)&real_AudioQueueStart},
        {"AudioQueueDispose", (void *)MyAudioQueueDispose, (void **)&real_AudioQueueDispose},
        {"AudioQueueProcessingTapNew", (void *)MyAudioQueueProcessingTapNew, (void **)&real_AudioQueueProcessingTapNew},
        {"AudioQueueProcessingTapGetSourceAudio", (void *)MyAudioQueueProcessingTapGetSourceAudio, (void **)&real_AudioQueueProcessingTapGetSourceAudio},
        {"AudioUnitRender", (void *)MyAudioUnitRender, (void **)&real_AudioUnitRender},
        {"AudioUnitSetProperty", (void *)MyAudioUnitSetProperty, (void **)&real_AudioUnitSetProperty},
        {"AudioQueueEnqueueBuffer", (void *)MyAudioQueueEnqueueBuffer, (void **)&real_AudioQueueEnqueueBuffer},
        {"AudioQueueEnqueueBufferWithParameters", (void *)MyAudioQueueEnqueueBufferWithParameters, (void **)&real_AudioQueueEnqueueBufferWithParameters},
        {"MTAudioProcessingTapGetSourceAudio", (void *)MyMTAudioProcessingTapGetSourceAudio, (void **)&real_MTAudioProcessingTapGetSourceAudio}
    };
    int ret = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    IGLog("[fishhook] rebind_symbols returned %d", ret);

    // 4. Objective-C Swizzling on FNFCoreAudioWrapper and AVPlayerItem
    InitFNFObjCSwizzling();
    InitAVPlayerItemSwizzling();
}

static void OnImageAdded(const struct mach_header *header, intptr_t slide) {
    PatchGOTPointersInAllImages((void *)AudioQueueStart, (void *)MyAudioQueueStart, "AudioQueueStart");
    PatchGOTPointersInAllImages((void *)AudioQueueDispose, (void *)MyAudioQueueDispose, "AudioQueueDispose");
    PatchGOTPointersInAllImages((void *)AudioQueueProcessingTapNew, (void *)MyAudioQueueProcessingTapNew, "AudioQueueProcessingTapNew");
    PatchGOTPointersInAllImages((void *)AudioQueueProcessingTapGetSourceAudio, (void *)MyAudioQueueProcessingTapGetSourceAudio, "AudioQueueProcessingTapGetSourceAudio");
    PatchGOTPointersInAllImages((void *)AudioUnitRender, (void *)MyAudioUnitRender, "AudioUnitRender");
    PatchGOTPointersInAllImages((void *)AudioUnitSetProperty, (void *)MyAudioUnitSetProperty, "AudioUnitSetProperty");
    PatchGOTPointersInAllImages((void *)AudioQueueEnqueueBuffer, (void *)MyAudioQueueEnqueueBuffer, "AudioQueueEnqueueBuffer");
    PatchGOTPointersInAllImages((void *)AudioQueueEnqueueBufferWithParameters, (void *)MyAudioQueueEnqueueBufferWithParameters, "AudioQueueEnqueueBufferWithParameters");
    PatchGOTPointersInAllImages((void *)MTAudioProcessingTapGetSourceAudio, (void *)MyMTAudioProcessingTapGetSourceAudio, "MTAudioProcessingTapGetSourceAudio");
}

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
    InstagramReverb_SetWetDry(0.35f, 0.65f);
    InstagramReverb_SetEnabled(true);
}

// ============================================================================
// Auto-Initialization Constructor
// ============================================================================
__attribute__((constructor))
static void InstagramReverbInit(void) {
    // 1. Install Signal Crash Handler (SIGSEGV, SIGBUS, SIGABRT, SIGILL)
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SignalCrashHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);

    NSSetUncaughtExceptionHandler(&UncaughtExceptionHandler);

    // 2. Initialize Persistent File Logger in Documents/
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    if (docDir) {
        NSString *logPath = [docDir stringByAppendingPathComponent:@"InstagramReverb.log"];
        NSString *crashPath = [docDir stringByAppendingPathComponent:@"InstagramReverb_crash.log"];
        snprintf(g_logFilePath, sizeof(g_logFilePath), "%s", [logPath UTF8String]);
        snprintf(g_crashFilePath, sizeof(g_crashFilePath), "%s", [crashPath UTF8String]);
        g_logFile = fopen(g_logFilePath, "a");
    }

    IGLog("==================================================================");
    IGLog("InstagramReverb Multi-Tier Engine Initializing... PID: %d, App: %s",
          getpid(), [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "Unknown");
    IGLog("Log file: %s", g_logFilePath[0] ? g_logFilePath : "Failed to resolve Documents dir");
    IGLog("Crash log file: %s", g_crashFilePath[0] ? g_crashFilePath : "Failed to resolve Documents dir");

    // 3. Initialize DSP state
    memset(&g_dsp, 0, sizeof(ReverbDSP));
    pthread_mutex_init(&g_dsp.lock, NULL);

    for (int i = 0; i < COMB_COUNT; ++i) {
        g_dsp.combL[i].bufSize = kCombLengthsL[i];
        g_dsp.combR[i].bufSize = kCombLengthsR[i];
    }
    for (int i = 0; i < ALLPASS_COUNT; ++i) {
        g_dsp.allpassL[i].bufSize = kAllpassLengthsL[i];
        g_dsp.allpassR[i].bufSize = kAllpassLengthsR[i];
    }

    g_dsp.roomSize = 0.82f;
    g_dsp.damping = 0.25f;
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

    // 4. Install all interception hooks across all 5 tiers
    InstallAllInterceptionHooks();

    // 5. Register image listener for dynamically loaded dylibs
    _dyld_register_func_for_add_image(OnImageAdded);

    IGLog("InstagramReverb Engine Initialized Successfully!");
    IGLog("==================================================================");
}
