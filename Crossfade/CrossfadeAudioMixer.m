#import "CrossfadeAudioMixer.h"
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* libVLC 3.x callback API. Kept local so this tweak does not depend on the
 * private MobileVLCKit headers at build time. */
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void (*libvlc_audio_play_cb)(void *data, const void *samples, unsigned count, int64_t pts);
typedef void (*libvlc_audio_pause_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_resume_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_flush_cb)(void *data, int64_t pts);
typedef void (*libvlc_audio_drain_cb)(void *data);
typedef void (*libvlc_audio_set_volume_cb)(void *data, float volume, bool mute);
typedef int (*libvlc_audio_setup_cb)(void **opaque, char *format, unsigned *rate, unsigned *channels);
typedef void (*libvlc_audio_cleanup_cb)(void *opaque);

extern void libvlc_audio_set_callbacks(libvlc_media_player_t *, libvlc_audio_play_cb,
                                       libvlc_audio_pause_cb, libvlc_audio_resume_cb,
                                       libvlc_audio_flush_cb, libvlc_audio_drain_cb, void *);
extern void libvlc_audio_set_format_callbacks(libvlc_media_player_t *, libvlc_audio_setup_cb,
                                              libvlc_audio_cleanup_cb);
extern void libvlc_audio_set_volume_callback(libvlc_media_player_t *, libvlc_audio_set_volume_cb);

extern void *class_getInstanceMethod(Class cls, SEL sel);

static const NSUInteger kRingFrames = 48000 * 6;
static const NSUInteger kMaxChannels = 2;

@interface CrossfadeAudioBuffer : NSObject
@property(nonatomic) uint32_t sampleRate;
@property(nonatomic) uint32_t channels;
@property(nonatomic) NSUInteger capacity;
@property(nonatomic) float *samples;
@property(nonatomic) _Atomic uint64_t writeFrame;
@property(nonatomic) _Atomic uint64_t readFrame;
@property(nonatomic) _Atomic BOOL flushing;
- (void)configureRate:(uint32_t)rate channels:(uint32_t)channels;
- (void)reset;
- (void)pushFloat32:(const float *)samples frames:(NSUInteger)frames;
- (NSUInteger)pullFloat32:(float *)out frames:(NSUInteger)frames;
@end

@implementation CrossfadeAudioBuffer

- (instancetype)init
{
    self = [super init];
    if (self) {
        _capacity = kRingFrames;
        _sampleRate = 48000;
        _channels = 2;
        _samples = calloc(_capacity * kMaxChannels, sizeof(float));
    }
    return self;
}

- (void)dealloc
{
    free(_samples);
}

- (void)configureRate:(uint32_t)rate channels:(uint32_t)channels
{
    if (rate == 0 || channels == 0 || channels > kMaxChannels)
        return;
    if (_sampleRate == rate && _channels == channels)
        return;
    _sampleRate = rate;
    _channels = channels;
    [self reset];
}

- (void)reset
{
    atomic_store(&_writeFrame, 0);
    atomic_store(&_readFrame, 0);
    memset(_samples, 0, _capacity * kMaxChannels * sizeof(float));
}

- (void)pushFloat32:(const float *)samples frames:(NSUInteger)frames
{
    if (!samples || frames == 0)
        return;

    uint64_t write = atomic_load_explicit(&_writeFrame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&_readFrame, memory_order_acquire);

    if (frames > _capacity)
        frames = _capacity;

    uint64_t available = _capacity - (write - read);
    if (frames > available) {
        uint64_t drop = frames - available;
        read += drop;
        atomic_store_explicit(&_readFrame, read, memory_order_release);
    }

    for (NSUInteger frame = 0; frame < frames; frame++) {
        NSUInteger dstFrame = (NSUInteger)((write + frame) % _capacity);
        const float *src = samples + frame * _channels;
        float *dst = _samples + dstFrame * kMaxChannels;
        if (_channels == 1) {
            dst[0] = src[0];
            dst[1] = src[0];
        } else {
            dst[0] = src[0];
            dst[1] = src[1];
        }
    }

    atomic_store_explicit(&_writeFrame, write + frames, memory_order_release);
}

- (NSUInteger)pullFloat32:(float *)out frames:(NSUInteger)frames
{
    if (!out || frames == 0)
        return 0;

    uint64_t read = atomic_load_explicit(&_readFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&_writeFrame, memory_order_acquire);
    uint64_t available = write - read;
    NSUInteger count = (NSUInteger)MIN((uint64_t)frames, available);

    for (NSUInteger frame = 0; frame < count; frame++) {
        NSUInteger srcFrame = (NSUInteger)((read + frame) % _capacity);
        const float *src = _samples + srcFrame * kMaxChannels;
        out[frame * 2] = src[0];
        out[frame * 2 + 1] = src[1];
    }

    atomic_store_explicit(&_readFrame, read + count, memory_order_release);
    return count;
}

@end

@interface CrossfadeAudioMixer ()
@property(nonatomic,strong) AVAudioEngine *engine;
@property(nonatomic,strong) AVAudioSourceNode *sourceNode;
@property(nonatomic,strong) CrossfadeAudioBuffer *primaryBuffer;
@property(nonatomic,strong) CrossfadeAudioBuffer *incomingBuffer;
@property(nonatomic) float primaryGain;
@property(nonatomic) float incomingGain;
@property(nonatomic) uint32_t sampleRate;
@property(nonatomic) uint32_t channels;
@property(nonatomic) BOOL configured;
@property(nonatomic) BOOL engineRunning;
@property(nonatomic) void *primaryHandle;
@property(nonatomic) void *incomingHandle;
@end

static int AudioSetup(void **opaque, char *format, unsigned *rate, unsigned *channels)
{
    CrossfadeAudioMixer *mixer = (__bridge CrossfadeAudioMixer *)(*opaque);
    if (format)
        memcpy(format, "FL32", 4);
    if (rate)
        *rate = mixer.sampleRate ?: 48000;
    if (channels)
        *channels = mixer.channels ?: 2;
    return 0;
}

static void AudioCleanup(void *opaque)
{
    (void)opaque;
}

static void AudioPlay(void *opaque, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    CrossfadeAudioMixer *mixer = (__bridge CrossfadeAudioMixer *)opaque;
    if (!mixer || !samples || count == 0)
        return;

    CrossfadeAudioBuffer *buffer = nil;
    if (mixer.primaryHandle) {
        /* The callback data is the mixer itself; which player generated the
         * callback is determined by the private bridge installed for each
         * player. */
    }
}

static void AudioPlayPrimary(void *opaque, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    CrossfadeAudioMixer *mixer = (__bridge CrossfadeAudioMixer *)opaque;
    [mixer.primaryBuffer pushFloat32:(const float *)samples frames:count];
}

static void AudioPlayIncoming(void *opaque, const void *samples, unsigned count, int64_t pts)
{
    (void)pts;
    CrossfadeAudioMixer *mixer = (__bridge CrossfadeAudioMixer *)(opaque);
    [mixer.incomingBuffer pushFloat32:(const float *)samples frames:count];
}

static void AudioNoopPause(void *opaque, int64_t pts) { (void)opaque; (void)pts; }
static void AudioNoopResume(void *opaque, int64_t pts) { (void)opaque; (void)pts; }
static void AudioFlush(void *opaque, int64_t pts)
{
    (void)pts;
    CrossfadeAudioMixer *mixer = (__bridge CrossfadeAudioMixer *)opaque;
    if (!mixer)
        return;
    [mixer.primaryBuffer reset];
    [mixer.incomingBuffer reset];
}
static void AudioDrain(void *opaque) { (void)opaque; }
static void AudioVolume(void *opaque, float volume, bool mute) { (void)opaque; (void)volume; (void)mute; }

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
    if (self) {
        _primaryBuffer = [CrossfadeAudioBuffer new];
        _incomingBuffer = [CrossfadeAudioBuffer new];
        _primaryGain = 1.0f;
        _incomingGain = 0.0f;
        _sampleRate = 48000;
        _channels = 2;
    }
    return self;
}

- (BOOL)ensureEngine
{
    if (self.engineRunning)
        return YES;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error];
    if (error)
        return NO;
    [session setActive:YES error:&error];
    if (error)
        return NO;

    self.engine = [AVAudioEngine new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:self.sampleRate channels:2];
    __weak CrossfadeAudioMixer *weakSelf = self;
    self.sourceNode = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL *isSilence,
                                                                                const AudioTimeStamp *timestamp,
                                                                                AVAudioFrameCount frameCount,
                                                                                AudioBufferList *audioBufferList) {
        (void)timestamp;
        CrossfadeAudioMixer *strongSelf = weakSelf;
        if (!strongSelf) {
            *isSilence = YES;
            return noErr;
        }

        float *out = (float *)audioBufferList->mBuffers[0].mData;
        NSUInteger frames = frameCount;
        float *primary = calloc(frames * 2, sizeof(float));
        float *incoming = calloc(frames * 2, sizeof(float));
        NSUInteger p = [strongSelf.primaryBuffer pullFloat32:primary frames:frames];
        NSUInteger i = [strongSelf.incomingBuffer pullFloat32:incoming frames:frames];

        if (audioBufferList->mNumberBuffers == 1) {
            for (NSUInteger frame = 0; frame < frames; frame++) {
                float left = 0.0f;
                float right = 0.0f;
                if (frame < p) {
                    left += primary[frame * 2] * strongSelf.primaryGain;
                    right += primary[frame * 2 + 1] * strongSelf.primaryGain;
                }
                if (frame < i) {
                    left += incoming[frame * 2] * strongSelf.incomingGain;
                    right += incoming[frame * 2 + 1] * strongSelf.incomingGain;
                }
                out[frame * 2] = left;
                out[frame * 2 + 1] = right;
            }
        } else {
            float *leftOut = (float *)audioBufferList->mBuffers[0].mData;
            float *rightOut = (float *)audioBufferList->mBuffers[1].mData;
            for (NSUInteger frame = 0; frame < frames; frame++) {
                float left = 0.0f;
                float right = 0.0f;
                if (frame < p) {
                    left += primary[frame * 2] * strongSelf.primaryGain;
                    right += primary[frame * 2 + 1] * strongSelf.primaryGain;
                }
                if (frame < i) {
                    left += incoming[frame * 2] * strongSelf.incomingGain;
                    right += incoming[frame * 2 + 1] * strongSelf.incomingGain;
                }
                leftOut[frame] = left;
                rightOut[frame] = right;
            }
        }

        free(primary);
        free(incoming);
        *isSilence = (p == 0 && i == 0);
        return noErr;
    }];

    [self.engine attachNode:self.sourceNode];
    [self.engine connect:self.sourceNode to:self.engine.mainMixerNode format:format];
    if (![self.engine startAndReturnError:&error])
        return NO;

    self.engineRunning = YES;
    return YES;
}

- (void)installCallbacksOnPlayer:(id)player incoming:(BOOL)incoming
{
    if (!player)
        return;

    void *handle = NULL;
    @try {
        handle = [player valueForKey:@"playerInstance"] ? (void *)[[player valueForKey:@"playerInstance"] pointerValue] : NULL;
    } @catch (__unused NSException *exception) {
        handle = NULL;
    }

    if (!handle) {
        Class cls = object_getClass(player);
        Ivar ivar = class_getInstanceVariable(cls, "_playerInstance");
        if (ivar)
            handle = *(void **)((uint8_t *)(__bridge void *)player + ivar_getOffset(ivar));
    }

    if (!handle)
        return;

    libvlc_audio_set_format_callbacks(handle, AudioSetup, AudioCleanup);
    if (incoming) {
        libvlc_audio_set_callbacks(handle, AudioPlayIncoming, AudioNoopPause, AudioNoopResume,
                                   AudioFlush, AudioDrain, (__bridge void *)self);
        self.incomingHandle = handle;
    } else {
        libvlc_audio_set_callbacks(handle, AudioPlayPrimary, AudioNoopPause, AudioNoopResume,
                                   AudioFlush, AudioDrain, (__bridge void *)self);
        self.primaryHandle = handle;
    }
    libvlc_audio_set_volume_callback(handle, AudioVolume);
}

- (BOOL)attachPrimaryPlayer:(id)primary
{
    if (![self ensureEngine])
        return NO;
    [self installCallbacksOnPlayer:primary incoming:NO];
    [self.primaryBuffer reset];
    return self.primaryHandle != NULL;
}

- (BOOL)prepareIncomingPlayer:(id)incoming
{
    if (![self ensureEngine])
        return NO;
    [self installCallbacksOnPlayer:incoming incoming:YES];
    [self.incomingBuffer reset];
    return self.incomingHandle != NULL;
}

- (void)setPrimaryGain:(float)gain
{
    _primaryGain = MAX(0.0f, MIN(gain, 1.0f));
}

- (void)setIncomingGain:(float)gain
{
    _incomingGain = MAX(0.0f, MIN(gain, 1.0f));
}

- (void)stopIncomingPlayer:(id)incoming
{
    if (!incoming)
        return;
    @try { [incoming performSelector:@selector(stop)]; } @catch (__unused NSException *exception) {}
    self.incomingHandle = NULL;
    [self.incomingBuffer reset];
}

- (void)detach
{
    [self.primaryBuffer reset];
    [self.incomingBuffer reset];
    self.primaryHandle = NULL;
    self.incomingHandle = NULL;
    self.primaryGain = 1.0f;
    self.incomingGain = 0.0f;

    if (self.engineRunning) {
        [self.engine stop];
        self.engineRunning = NO;
    }
    self.engine = nil;
    self.sourceNode = nil;
}

@end
