#import "CrossfadeAudioMixer.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void (*libvlc_audio_play_cb)(void *data, const void *samples, unsigned count, int64_t pts);
typedef void (*libvlc_audio_pause_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_resume_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_flush_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_drain_cb)(void *data);
typedef void (*libvlc_audio_set_volume_cb)(void *data, float volume, bool mute);

typedef void (*SetCallbacksFn)(libvlc_media_player_t *, libvlc_audio_play_cb,
                               libvlc_audio_pause_cb, libvlc_audio_resume_cb,
                               libvlc_audio_flush_cb, libvlc_audio_drain_cb, void *);
typedef void (*SetFormatFn)(libvlc_media_player_t *, const char *, unsigned, unsigned);
typedef void (*SetVolumeCallbackFn)(libvlc_media_player_t *, libvlc_audio_set_volume_cb);

static SetCallbacksFn sSetCallbacks;
static SetFormatFn sSetFormat;
static SetVolumeCallbackFn sSetVolumeCallback;
static dispatch_once_t sResolveOnce;

static void ResolveLibVLCAudioAPI(void)
{
    dispatch_once(&sResolveOnce, ^{
        sSetCallbacks = (SetCallbacksFn)dlsym(RTLD_DEFAULT, "libvlc_audio_set_callbacks");
        sSetFormat = (SetFormatFn)dlsym(RTLD_DEFAULT, "libvlc_audio_set_format");
        sSetVolumeCallback = (SetVolumeCallbackFn)dlsym(RTLD_DEFAULT, "libvlc_audio_set_volume_callback");
    });
}

#define CF_SAMPLE_RATE 48000u
#define CF_CHANNELS 2u
#define CF_RING_FRAMES (CF_SAMPLE_RATE * 8u)

typedef struct {
    float *data;
    uint64_t capacity;
    uint32_t channels;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t writeFrame;
    _Atomic bool active;
} CrossfadeRing;

typedef struct {
    CrossfadeRing primary;
    CrossfadeRing incoming;
    _Atomic float primaryGain;
    _Atomic float incomingGain;
} CrossfadeMixerState;

static bool RingInit(CrossfadeRing *ring, uint64_t capacity, uint32_t channels)
{
    ring->data = calloc((size_t)(capacity * channels), sizeof(float));
    if (!ring->data)
        return false;
    ring->capacity = capacity;
    ring->channels = channels;
    atomic_init(&ring->readFrame, 0);
    atomic_init(&ring->writeFrame, 0);
    atomic_init(&ring->active, true);
    return true;
}

static void RingDestroy(CrossfadeRing *ring)
{
    free(ring->data);
    ring->data = NULL;
}

static void RingReset(CrossfadeRing *ring)
{
    atomic_store_explicit(&ring->readFrame, 0, memory_order_release);
    atomic_store_explicit(&ring->writeFrame, 0, memory_order_release);
}

static void RingWrite(CrossfadeRing *ring, const float *samples, unsigned frames)
{
    if (!ring || !ring->data || !samples || frames == 0)
        return;

    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_acquire);
    uint64_t count = frames;

    if (count > ring->capacity)
        count = ring->capacity;

    uint64_t used = write - read;
    if (used > ring->capacity)
        read = write - ring->capacity;

    uint64_t freeFrames = ring->capacity - (write - read);
    if (count > freeFrames) {
        read += count - freeFrames;
        atomic_store_explicit(&ring->readFrame, read, memory_order_release);
    }

    const uint32_t channels = ring->channels;
    const uint64_t capacity = ring->capacity;
    for (uint64_t frame = 0; frame < count; frame++) {
        uint64_t dstFrame = (write + frame) % capacity;
        float *dst = ring->data + dstFrame * channels;
        const float *src = samples + frame * channels;
        if (channels == 1) {
            dst[0] = src[0];
            dst[1] = src[0];
        } else {
            dst[0] = src[0];
            dst[1] = src[1];
        }
    }

    atomic_store_explicit(&ring->writeFrame, write + count, memory_order_release);
}

static void RingMixInterleaved(CrossfadeRing *ring, float *out, uint64_t frames, float gain)
{
    if (!ring || !ring->data || !out || frames == 0)
        return;
    if (!atomic_load_explicit(&ring->active, memory_order_acquire))
        return;

    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);
    uint64_t available = write - read;
    uint64_t count = available < frames ? available : frames;
    const uint64_t capacity = ring->capacity;
    const uint32_t channels = ring->channels;

    for (uint64_t frame = 0; frame < count; frame++) {
        uint64_t srcFrame = (read + frame) % capacity;
        const float *src = ring->data + srcFrame * channels;
        if (channels == 1) {
            out[frame * 2] += src[0] * gain;
            out[frame * 2 + 1] += src[0] * gain;
        } else {
            out[frame * 2] += src[0] * gain;
            out[frame * 2 + 1] += src[1] * gain;
        }
    }

    atomic_store_explicit(&ring->readFrame, read + count, memory_order_release);
}

static void RingMixNonInterleaved(CrossfadeRing *ring, float *leftOut, float *rightOut,
                                  uint64_t frames, float gain)
{
    if (!ring || !ring->data || !leftOut || !rightOut || frames == 0)
        return;
    if (!atomic_load_explicit(&ring->active, memory_order_acquire))
        return;

    uint64_t read = atomic_load_explicit(&ring->readFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);
    uint64_t available = write - read;
    uint64_t count = available < frames ? available : frames;
    const uint64_t capacity = ring->capacity;
    const uint32_t channels = ring->channels;

    for (uint64_t frame = 0; frame < count; frame++) {
        uint64_t srcFrame = (read + frame) % capacity;
        const float *src = ring->data + srcFrame * channels;
        if (channels == 1) {
            leftOut[frame] += src[0] * gain;
            rightOut[frame] += src[0] * gain;
        } else {
            leftOut[frame] += src[0] * gain;
            rightOut[frame] += src[1] * gain;
        }
    }

    atomic_store_explicit(&ring->readFrame, read + count, memory_order_release);
}

static void AudioPlayPrimary(void *opaque, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    RingWrite(&((CrossfadeMixerState *)opaque)->primary, samples, count);
}

static void AudioPlayIncoming(void *opaque, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    RingWrite(&((CrossfadeMixerState *)opaque)->incoming, samples, count);
}

static void AudioPausePrimary(void *opaque, int64_t pts)
{
    (void)pts;
    CrossfadeMixerState *state = opaque;
    atomic_store_explicit(&state->primary.active, false, memory_order_release);
    RingReset(&state->primary);
}

static void AudioPauseIncoming(void *opaque, int64_t pts)
{
    (void)pts;
    CrossfadeMixerState *state = opaque;
    atomic_store_explicit(&state->incoming.active, false, memory_order_release);
    RingReset(&state->incoming);
}

static void AudioResumePrimary(void *opaque, int64_t pts)
{
    (void)pts;
    atomic_store_explicit(&((CrossfadeMixerState *)opaque)->primary.active, true, memory_order_release);
}

static void AudioResumeIncoming(void *opaque, int64_t pts)
{
    (void)pts;
    atomic_store_explicit(&((CrossfadeMixerState *)opaque)->incoming.active, true, memory_order_release);
}

static void AudioFlushPrimary(void *opaque, int64_t pts)
{
    (void)pts;
    RingReset(&((CrossfadeMixerState *)opaque)->primary);
}

static void AudioFlushIncoming(void *opaque, int64_t pts)
{
    (void)pts;
    RingReset(&((CrossfadeMixerState *)opaque)->incoming);
}

static void AudioDrain(void *opaque) { (void)opaque; }
static void AudioVolume(void *opaque, float volume, bool mute) { (void)opaque; (void)volume; (void)mute; }

static void RenderMixer(CrossfadeMixerState *state, AudioBufferList *audioBufferList, AVAudioFrameCount frameCount)
{
    if (!state || !audioBufferList || frameCount == 0)
        return;

    float primaryGain = atomic_load_explicit(&state->primaryGain, memory_order_relaxed);
    float incomingGain = atomic_load_explicit(&state->incomingGain, memory_order_relaxed);
    uint64_t frames = frameCount;
    NSUInteger buffers = audioBufferList->mNumberBuffers;

    if (buffers == 1 && audioBufferList->mBuffers[0].mNumberChannels >= 2) {
        float *out = audioBufferList->mBuffers[0].mData;
        if (!out)
            return;
        memset(out, 0, (size_t)(frames * 2 * sizeof(float)));
        RingMixInterleaved(&state->primary, out, frames, primaryGain);
        RingMixInterleaved(&state->incoming, out, frames, incomingGain);
    } else if (buffers >= 2) {
        float *left = audioBufferList->mBuffers[0].mData;
        float *right = audioBufferList->mBuffers[1].mData;
        if (!left || !right)
            return;
        memset(left, 0, (size_t)(frames * sizeof(float)));
        memset(right, 0, (size_t)(frames * sizeof(float)));
        RingMixNonInterleaved(&state->primary, left, right, frames, primaryGain);
        RingMixNonInterleaved(&state->incoming, left, right, frames, incomingGain);
    }
}

@interface CrossfadeAudioMixer ()
@property(nonatomic,strong) AVAudioEngine *engine;
@property(nonatomic,strong) AVAudioSourceNode *sourceNode;
@property(nonatomic) CrossfadeMixerState *state;
@property(nonatomic) void *primaryHandle;
@property(nonatomic) void *incomingHandle;
@property(nonatomic) BOOL engineRunning;
@end

@implementation CrossfadeAudioMixer

+ (instancetype)sharedMixer
{
    static CrossfadeAudioMixer *mixer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mixer = [self new]; });
    return mixer;
}

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    _state = calloc(1, sizeof(*_state));
    if (!_state)
        return nil;

    if (!RingInit(&_state->primary, CF_RING_FRAMES, CF_CHANNELS) ||
        !RingInit(&_state->incoming, CF_RING_FRAMES, CF_CHANNELS)) {
        RingDestroy(&_state->primary);
        RingDestroy(&_state->incoming);
        free(_state);
        _state = NULL;
        return nil;
    }

    atomic_init(&_state->primaryGain, 1.0f);
    atomic_init(&_state->incomingGain, 0.0f);
    return self;
}

- (void)dealloc
{
    [self detach];
    if (_state) {
        RingDestroy(&_state->primary);
        RingDestroy(&_state->incoming);
        free(_state);
        _state = NULL;
    }
}

- (BOOL)ensureEngine
{
    if (self.engineRunning)
        return YES;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setActive:YES error:&error];
    if (error)
        return NO;

    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:CF_SAMPLE_RATE
                                                                              channels:CF_CHANNELS];
    CrossfadeMixerState *state = self.state;
    AVAudioSourceNode *sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format
                                                                  renderBlock:^OSStatus(BOOL *isSilence,
                                                                                        const AudioTimeStamp *timestamp,
                                                                                        AVAudioFrameCount frameCount,
                                                                                        AudioBufferList *audioBufferList) {
        (void)timestamp;
        RenderMixer(state, audioBufferList, frameCount);
        *isSilence = false;
        return noErr;
    }];

    [engine attachNode:sourceNode];
    [engine connect:sourceNode to:engine.mainMixerNode format:format];
    if (![engine startAndReturnError:&error])
        return NO;

    self.engine = engine;
    self.sourceNode = sourceNode;
    self.engineRunning = YES;
    return YES;
}

static void *PlayerHandle(id player)
{
    if (!player)
        return NULL;

    SEL selector = NSSelectorFromString(@"playerInstance");
    if ([player respondsToSelector:selector]) {
        void *(*getter)(id, SEL) = (void *)objc_msgSend;
        return getter(player, selector);
    }

    selector = NSSelectorFromString(@"libVLCMediaPlayer");
    if ([player respondsToSelector:selector]) {
        void *(*getter)(id, SEL) = (void *)objc_msgSend;
        return getter(player, selector);
    }

    Class cls = object_getClass(player);
    Ivar ivar = class_getInstanceVariable(cls, "_playerInstance");
    if (!ivar)
        return NULL;
    return *(void **)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivar));
}

- (BOOL)installCallbacksOnPlayer:(id)player incoming:(BOOL)incoming
{
    void *handle = PlayerHandle(player);
    if (!handle)
        return NO;

    ResolveLibVLCAudioAPI();
    if (!sSetCallbacks || !sSetFormat)
        return NO;

    sSetFormat(handle, "FL32", CF_SAMPLE_RATE, CF_CHANNELS);

    CrossfadeMixerState *state = self.state;
    if (incoming) {
        sSetCallbacks(handle, AudioPlayIncoming, AudioPauseIncoming, AudioResumeIncoming,
                      AudioFlushIncoming, AudioDrain, state);
        self.incomingHandle = handle;
    } else {
        sSetCallbacks(handle, AudioPlayPrimary, AudioPausePrimary, AudioResumePrimary,
                      AudioFlushPrimary, AudioDrain, state);
        self.primaryHandle = handle;
    }

    if (sSetVolumeCallback)
        sSetVolumeCallback(handle, AudioVolume);

    return YES;
}

- (BOOL)attachPrimaryPlayer:(id)primary
{
    if (!self.state || ![self ensureEngine] || ![self installCallbacksOnPlayer:primary incoming:NO])
        return NO;

    atomic_store_explicit(&self.state->primary.active, true, memory_order_release);
    atomic_store_explicit(&self.state->primaryGain, 1.0f, memory_order_release);
    atomic_store_explicit(&self.state->incomingGain, 0.0f, memory_order_release);
    RingReset(&self.state->primary);
    RingReset(&self.state->incoming);
    return YES;
}

- (BOOL)preparePrimaryPlayer:(id)player
{
    if (!self.state || ![self ensureEngine] || ![self installCallbacksOnPlayer:player incoming:NO])
        return NO;

    atomic_store_explicit(&self.state->primary.active, true, memory_order_release);
    atomic_store_explicit(&self.state->primaryGain, 0.0f, memory_order_release);
    RingReset(&self.state->primary);
    return YES;
}

- (BOOL)prepareIncomingPlayer:(id)incoming
{
    if (!self.state || ![self ensureEngine] || ![self installCallbacksOnPlayer:incoming incoming:YES])
        return NO;

    atomic_store_explicit(&self.state->incoming.active, true, memory_order_release);
    atomic_store_explicit(&self.state->incomingGain, 0.0f, memory_order_release);
    RingReset(&self.state->incoming);
    return YES;
}

- (void)setPrimaryGain:(float)gain
{
    if (self.state)
        atomic_store_explicit(&self.state->primaryGain, MAX(0.0f, MIN(gain, 2.0f)), memory_order_release);
}

- (void)setIncomingGain:(float)gain
{
    if (self.state)
        atomic_store_explicit(&self.state->incomingGain, MAX(0.0f, MIN(gain, 2.0f)), memory_order_release);
}

- (void)setPrimaryActive:(BOOL)active
{
    if (self.state)
        atomic_store_explicit(&self.state->primary.active, active, memory_order_release);
}

- (void)setIncomingActive:(BOOL)active
{
    if (self.state)
        atomic_store_explicit(&self.state->incoming.active, active, memory_order_release);
}

- (void)stopPrimaryPlayer:(id)primary
{
    if (self.state) {
        atomic_store_explicit(&self.state->primary.active, false, memory_order_release);
        RingReset(&self.state->primary);
    }

    if (primary && [primary respondsToSelector:@selector(stop)]) {
        void (*stop)(id, SEL) = (void *)objc_msgSend;
        stop(primary, @selector(stop));
    }
    self.primaryHandle = NULL;
}

- (void)stopIncomingPlayer:(id)incoming
{
    if (self.state) {
        atomic_store_explicit(&self.state->incoming.active, false, memory_order_release);
        RingReset(&self.state->incoming);
    }

    if (incoming && [incoming respondsToSelector:@selector(stop)]) {
        void (*stop)(id, SEL) = (void *)objc_msgSend;
        stop(incoming, @selector(stop));
    }
    self.incomingHandle = NULL;
}

- (void)detach
{
    if (!_state)
        return;

    atomic_store_explicit(&_state->primary.active, false, memory_order_release);
    atomic_store_explicit(&_state->incoming.active, false, memory_order_release);
    RingReset(&_state->primary);
    RingReset(&_state->incoming);
    atomic_store_explicit(&_state->primaryGain, 1.0f, memory_order_release);
    atomic_store_explicit(&_state->incomingGain, 0.0f, memory_order_release);
    self.primaryHandle = NULL;
    self.incomingHandle = NULL;

    if (self.engineRunning) {
        [self.engine stop];
        self.engineRunning = NO;
    }
    self.sourceNode = nil;
    self.engine = nil;
}

@end
