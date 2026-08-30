#import "CrossfadeController.h"
#import "CrossfadeAudioMixer.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>

static NSString * const kDurationKey = @"CrossfadeDuration";
static const NSInteger kRepeatCurrent = 1;
static const NSInteger kRepeatAll = 2;
static const NSTimeInterval kHandoffRamp = 0.18;
static const NSTimeInterval kHandoffTolerance = 0.20;
static const NSTimeInterval kMaxHandoffWait = 3.0;

@interface CrossfadeController ()
@property(nonatomic,weak) id service;
@property(nonatomic,strong) id primary;
@property(nonatomic,strong) id incoming;
@property(nonatomic,strong) id incomingMedia;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSTimer *handoffTimer;
@property(nonatomic) BOOL fading;
@property(nonatomic) BOOL transitionPending;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL internalVolume;
@property(nonatomic) BOOL handoffFading;
@property(nonatomic) BOOL mixerAttached;
@property(nonatomic) NSInteger volume;
@property(nonatomic) NSTimeInterval fadeDuration;
@property(nonatomic) NSTimeInterval handoffStarted;
@property(nonatomic) NSTimeInterval handoffTargetTime;
@end

@implementation CrossfadeController

+ (instancetype)sharedController
{
    static CrossfadeController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    return controller;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _volume = 100;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(settingsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelTransition:YES];
    [[CrossfadeAudioMixer sharedMixer] detach];
}

- (NSTimeInterval)duration
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kDurationKey])
        return 0.0;

    double value = [defaults doubleForKey:kDurationKey];
    if (!isfinite(value))
        return 0.0;
    return MIN(MAX(value, 0.0), 15.0);
}

- (void)attachToPlaybackService:(id)service
{
    if (self.service != service)
        [self cancelTransition:YES];

    self.service = service;
    self.primary = [self servicePlayer];

    if (!self.primary) {
        self.mixerAttached = NO;
        return;
    }

    self.volume = [self volumeOf:self.primary];
    self.mixerAttached = [[CrossfadeAudioMixer sharedMixer] attachPrimaryPlayer:self.primary];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:0.0];
    [self startTimer];
}

- (void)detach
{
    [self cancelTransition:YES];
    [self stopTimer];
    [self stopHandoffTimer];
    [[CrossfadeAudioMixer sharedMixer] detach];
    self.mixerAttached = NO;
    self.service = nil;
    self.primary = nil;
}

- (void)playbackStarted
{
    id player = [self servicePlayer];
    if (player && player != self.primary) {
        [self cancelTransition:YES];
        self.primary = player;
        self.mixerAttached = [[CrossfadeAudioMixer sharedMixer] attachPrimaryPlayer:player];
    }

    if (!self.primary)
        self.primary = player;

    if (self.primary && !self.fading && !self.incoming) {
        NSInteger currentVolume = [self volumeOf:self.primary];
        if (currentVolume >= 0)
            self.volume = currentVolume;
        [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:YES];
        [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
        [[CrossfadeAudioMixer sharedMixer] setIncomingGain:0.0];
    }

    [self startTimer];
}

- (void)playbackStopped
{
    [self cancelTransition:YES];
    [self stopTimer];
    [self stopHandoffTimer];
    [[CrossfadeAudioMixer sharedMixer] detach];
    self.mixerAttached = NO;
}

- (void)playbackPaused:(BOOL)paused
{
    self.paused = paused;
    [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:!paused];
    [[CrossfadeAudioMixer sharedMixer] setIncomingActive:!paused];

    if (paused) {
        [self call:self.incoming sel:@selector(pause)];
        [self stopTimer];
        [self stopHandoffTimer];
    } else {
        [self call:self.incoming sel:@selector(play)];
        [self startTimer];
        if (self.transitionPending)
            [self startHandoffTimer];
    }
}

- (void)manualNavigation
{
    [self cancelTransition:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self playbackStarted];
    });
}

- (void)positionChanged
{
    if (self.fading || self.incoming || self.transitionPending)
        [self cancelTransition:YES];
    [self startTimer];
}

- (void)primaryReachedEnd
{
    if (!self.incoming || !self.fading)
        return;

    self.transitionPending = YES;
    self.handoffStarted = CFAbsoluteTimeGetCurrent();
    self.handoffTargetTime = [self currentTime:self.incoming];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:0.0];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:[self gainForVolume:self.volume]];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:NO];
    [self stopTimer];
}

- (void)primaryStateChanged
{
    if (!self.transitionPending || !self.incoming)
        return;
    self.handoffStarted = CFAbsoluteTimeGetCurrent();
    [self startHandoffTimer];
}

- (void)userVolumeChanged:(NSInteger)value
{
    if (self.internalVolume)
        return;

    self.volume = MIN(MAX(value, 0), 200);
    float gain = [self gainForVolume:self.volume];

    if (self.fading) {
        if (!self.handoffFading)
            [[CrossfadeAudioMixer sharedMixer] setIncomingGain:MAX(0.0f, MIN(gain, 2.0f))];
        return;
    }

    if (self.transitionPending) {
        [[CrossfadeAudioMixer sharedMixer] setIncomingGain:gain];
        return;
    }

    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:gain];
}

- (float)gainForVolume:(NSInteger)value
{
    return MIN(MAX((float)value / 100.0f, 0.0f), 2.0f);
}

- (void)startTimer
{
    if (self.timer || self.paused || !self.mixerAttached || [self duration] <= 0.0 || self.transitionPending)
        return;

    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                   target:self
                                                 selector:@selector(tick:)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (void)stopTimer
{
    [self.timer invalidate];
    self.timer = nil;
}

- (void)startHandoffTimer
{
    if (self.handoffTimer || self.paused || !self.incoming || !self.transitionPending)
        return;

    self.handoffTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                          target:self
                                                        selector:@selector(handoffTick:)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)stopHandoffTimer
{
    [self.handoffTimer invalidate];
    self.handoffTimer = nil;
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    if (self.paused || !self.service || !self.primary || self.transitionPending)
        return;

    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) {
        [self cancelTransition:YES];
        [self stopTimer];
        return;
    }

    if (!self.fading) {
        NSTimeInterval remaining = [self remaining:self.primary];
        if (remaining > 0.0 && remaining <= duration) {
            id next = [self nextMedia];
            if (next && [self begin:next duration:duration]) {
                return;
            }
        }
        return;
    }

    NSTimeInterval remaining = [self remaining:self.primary];
    CGFloat progress = (CGFloat)MIN(MAX(1.0 - remaining / self.fadeDuration, 0.0), 1.0);
    CGFloat theta = progress * (CGFloat)(M_PI_2);
    float baseGain = [self gainForVolume:self.volume];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:baseGain * cosf(theta)];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:baseGain * sinf(theta)];
}

- (void)handoffTick:(NSTimer *)timer
{
    (void)timer;

    if (self.paused || !self.incoming || !self.transitionPending || !self.primary)
        return;

    id primaryMedia = [self mediaOf:self.primary];
    if (!primaryMedia || !self.incomingMedia || [primaryMedia compare:self.incomingMedia] != NSOrderedSame) {
        if (CFAbsoluteTimeGetCurrent() - self.handoffStarted > kMaxHandoffWait) {
            [self abandonHandoffAndRestorePrimary];
        }
        return;
    }

    BOOL seekable = [self boolValue:self.primary key:@"seekable" defaultValue:NO];
    NSTimeInterval incomingTime = [self currentTime:self.incoming];
    NSTimeInterval primaryTime = [self currentTime:self.primary];
    if (incomingTime < 0.0 || primaryTime < 0.0) {
        if (CFAbsoluteTimeGetCurrent() - self.handoffStarted > kMaxHandoffWait)
            [self abandonHandoffAndRestorePrimary];
        return;
    }

    if (!seekable) {
        [self abandonHandoffAndRestorePrimary];
        return;
    }

    if (fabs(primaryTime - incomingTime) > kHandoffTolerance || primaryTime < self.handoffTargetTime - kHandoffTolerance) {
        [self setTime:incomingTime player:self.primary];
        primaryTime = [self currentTime:self.primary];
    }

    if (!self.handoffFading) {
        if (fabs(primaryTime - incomingTime) > kHandoffTolerance) {
            if (CFAbsoluteTimeGetCurrent() - self.handoffStarted > kMaxHandoffWait)
                [self abandonHandoffAndRestorePrimary];
            return;
        }
        [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:YES];
        self.handoffFading = YES;
        self.handoffStarted = CFAbsoluteTimeGetCurrent();
    }

    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.handoffStarted;
    CGFloat progress = (CGFloat)MIN(MAX(elapsed / kHandoffRamp, 0.0), 1.0);
    float baseGain = [self gainForVolume:self.volume];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:baseGain * sinf((CGFloat)(M_PI_2) * progress)];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:baseGain * cosf((CGFloat)(M_PI_2) * progress)];

    if (progress >= 1.0) {
        [[CrossfadeAudioMixer sharedMixer] stopIncomingPlayer:self.incoming];
        self.incoming = nil;
        self.incomingMedia = nil;
        self.fading = NO;
        self.transitionPending = NO;
        self.handoffFading = NO;
        [self stopHandoffTimer];
        [self startTimer];
    }
}

- (void)abandonHandoffAndRestorePrimary
{
    [[CrossfadeAudioMixer sharedMixer] stopIncomingPlayer:self.incoming];
    self.incoming = nil;
    self.incomingMedia = nil;
    self.fading = NO;
    self.transitionPending = NO;
    self.handoffFading = NO;
    [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:YES];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:0.0];
    [self stopHandoffTimer];
    [self startTimer];
}

- (id)nextMedia
{
    @try {
        BOOL shuffle = [[self.service valueForKey:@"shuffleMode"] boolValue];
        id list = shuffle ? [self.service valueForKey:@"shuffledList"] : [self.service valueForKey:@"mediaList"];
        id current = [self.service valueForKey:@"currentlyPlayingMedia"];
        if (!list || !current)
            return nil;

        NSInteger count = [[list valueForKey:@"count"] integerValue];
        if (count < 1)
            return nil;

        NSInteger (*indexOf)(id, SEL, id) = (void *)objc_msgSend;
        NSInteger index = indexOf(list, @selector(indexOfMedia:), current);
        if (index < 0)
            return nil;

        NSInteger repeat = [[self.service valueForKey:@"repeatMode"] integerValue];
        NSInteger nextIndex = -1;
        if (repeat == kRepeatCurrent)
            nextIndex = index;
        else if (index + 1 < count)
            nextIndex = index + 1;
        else if (repeat == kRepeatAll)
            nextIndex = 0;

        if (nextIndex < 0)
            return nil;

        id (*mediaAt)(id, SEL, NSUInteger) = (void *)objc_msgSend;
        return mediaAt(list, @selector(mediaAtIndex:), (NSUInteger)nextIndex);
    }
    @catch (__unused NSException *exception) {
        return nil;
    }
}

- (BOOL)begin:(id)media duration:(NSTimeInterval)duration
{
    if (self.fading || self.incoming || !media || !self.primary)
        return NO;

    if (![self boolValue:self.primary key:@"seekable" defaultValue:NO])
        return NO;

    id player = [self makePlayer:media];
    if (!player)
        return NO;

    if (![[CrossfadeAudioMixer sharedMixer] prepareIncomingPlayer:player])
        return NO;

    self.incomingMedia = media;
    self.incoming = player;
    self.fadeDuration = duration;
    self.fading = YES;
    self.transitionPending = NO;
    self.handoffFading = NO;

    [[CrossfadeAudioMixer sharedMixer] setIncomingActive:YES];
    [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:0.0];
    [self call:player sel:@selector(play)];
    return YES;
}

- (id)servicePlayer
{
    id player = nil;
    @try { player = [self.service valueForKey:@"_mediaPlayer"]; }
    @catch (__unused NSException *exception) {}
    if (!player) {
        @try { player = [self.service valueForKey:@"mediaPlayer"]; }
        @catch (__unused NSException *exception) {}
    }
    return player;
}

- (id)makePlayer:(id)media
{
    @try {
        Class playerClass = NSClassFromString(@"VLCMediaPlayer");
        if (!playerClass)
            return nil;

        id library = [self.primary valueForKey:@"libraryInstance"];
        id player = nil;
        if (library) {
            id allocated = [playerClass alloc];
            id (*initializer)(id, SEL, id) = (void *)objc_msgSend;
            player = initializer(allocated, @selector(initWithLibrary:), library);
        }
        if (!player)
            player = [[playerClass alloc] init];
        if (!player)
            return nil;

        [player setValue:media forKey:@"media"];
        @try { [player setValue:@(-1) forKey:@"currentVideoTrackIndex"]; }
        @catch (__unused NSException *exception) {}

        float rate = 1.0f;
        @try { rate = [[self.primary valueForKey:@"rate"] floatValue]; }
        @catch (__unused NSException *exception) {}
        if (rate > 0.0f)
            [player setValue:@(rate) forKey:@"rate"];

        return player;
    }
    @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSTimeInterval)remaining:(id)player
{
    @try {
        id media = [player valueForKey:@"media"];
        double total = [[media valueForKey:@"length"] doubleValue] / 1000.0;
        double current = [[player valueForKey:@"time"] doubleValue] / 1000.0;
        float rate = [[player valueForKey:@"rate"] floatValue];
        if (rate <= 0.0f)
            rate = 1.0f;
        if (total <= 0.0 || current < 0.0 || current > total)
            return DBL_MAX;
        return MAX(0.0, (total - current) / rate);
    }
    @catch (__unused NSException *exception) {
        return DBL_MAX;
    }
}

- (NSTimeInterval)currentTime:(id)player
{
    @try {
        double value = [[player valueForKey:@"time"] doubleValue] / 1000.0;
        return value >= 0.0 ? value : -1.0;
    }
    @catch (__unused NSException *exception) {
        return -1.0;
    }
}

- (id)mediaOf:(id)player
{
    @try { return [player valueForKey:@"media"]; }
    @catch (__unused NSException *exception) { return nil; }
}

- (void)setTime:(NSTimeInterval)seconds player:(id)player
{
    if (!player || seconds < 0.0)
        return;

    @try {
        Class timeClass = NSClassFromString(@"VLCTime");
        if (!timeClass)
            return;

        id (*factory)(id, SEL, id) = (void *)objc_msgSend;
        id time = factory(timeClass, @selector(timeWithNumber:), @(llround(seconds * 1000.0)));
        [player setValue:time forKey:@"time"];
    }
    @catch (__unused NSException *exception) {}
}

- (BOOL)boolValue:(id)object key:(NSString *)key defaultValue:(BOOL)fallback
{
    @try { return [object valueForKey:key] ? [[object valueForKey:key] boolValue] : fallback; }
    @catch (__unused NSException *exception) { return fallback; }
}

- (NSInteger)volumeOf:(id)player
{
    if (!player)
        return self.volume;

    @try {
        NSInteger value = [[[[player valueForKey:@"audio"] valueForKey:@"volume"] description] integerValue];
        if (value < 0)
            return self.volume;
        return MIN(MAX(value, 0), 200);
    }
    @catch (__unused NSException *exception) {
        return self.volume;
    }
}

- (void)stop:(id)player
{
    if (player)
        [self call:player sel:@selector(stop)];
}

- (void)call:(id)object sel:(SEL)selector
{
    if (!object || ![object respondsToSelector:selector])
        return;

    void (*function)(id, SEL) = (void *)objc_msgSend;
    function(object, selector);
}

- (void)cancelTransition:(BOOL)restore
{
    [self stopHandoffTimer];
    [[CrossfadeAudioMixer sharedMixer] stopIncomingPlayer:self.incoming];

    self.incoming = nil;
    self.incomingMedia = nil;
    self.fading = NO;
    self.transitionPending = NO;
    self.handoffFading = NO;

    [[CrossfadeAudioMixer sharedMixer] setIncomingGain:0.0];
    if (restore) {
        [[CrossfadeAudioMixer sharedMixer] setPrimaryActive:YES];
        [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
    }
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self duration] <= 0.0)
            [self cancelTransition:YES];
        else
            [self startTimer];
    });
}

- (void)interruption:(NSNotification *)notification
{
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan)
        [self playbackPaused:YES];
    else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded)
        [self playbackPaused:NO];
}

- (void)routeChanged:(NSNotification *)notification
{
    (void)notification;
    if (self.fading || self.incoming || self.transitionPending)
        [self cancelTransition:YES];
}

@end
