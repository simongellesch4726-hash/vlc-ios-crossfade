#import "CrossfadeController.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>

static NSString * const kCrossfadeDurationKey = @"CrossfadeDuration";
static const NSInteger kVLCRepeatCurrentItem = 1;
static const NSInteger kVLCRepeatAllItems = 2;

@interface CrossfadeController ()
@property (nonatomic, weak) id service;
@property (nonatomic, strong) id primaryPlayer;
@property (nonatomic, strong) id activeAudioPlayer;
@property (nonatomic, strong) id preparedAudioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL fading;
@property (nonatomic) BOOL internalVolumeChange;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL inTransition;
@property (nonatomic) NSInteger desiredVolume;
@property (nonatomic) CFTimeInterval fadeStart;
@property (nonatomic) NSTimeInterval fadeDuration;
@property (nonatomic, strong) id fadeOutgoingPlayer;
@property (nonatomic, strong) id fadeIncomingPlayer;
@end

@implementation CrossfadeController

+ (instancetype)sharedController
{
    static CrossfadeController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [CrossfadeController new]; });
    return controller;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _desiredVolume = 100;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(settingsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(audioInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelFadeAndRestore:YES];
}

- (NSTimeInterval)configuredDuration
{
    double value = [[NSUserDefaults standardUserDefaults] doubleForKey:kCrossfadeDurationKey];
    if (!isfinite(value)) return 0.0;
    return MIN(MAX(value, 0.0), 15.0);
}

- (void)attachToPlaybackService:(id)service
{
    self.service = service;
    if (!service) return;
    @try { self.primaryPlayer = [service valueForKey:@"_mediaPlayer"]; } @catch (__unused NSException *e) {}
    if (!self.primaryPlayer) @try { self.primaryPlayer = [service valueForKey:@"mediaPlayer"]; } @catch (__unused NSException *e) {}
    NSInteger volume = [self audioVolumeForPlayer:self.primaryPlayer];
    if (volume > 0) self.desiredVolume = volume;
    [self startTimerIfNeeded];
}

- (void)detach
{
    [self cancelFadeAndRestore:YES];
    [self stopTimer];
    self.service = nil;
    self.primaryPlayer = nil;
}

- (void)playbackStarted
{
    id service = self.service;
    if (service) @try { self.primaryPlayer = [service valueForKey:@"_mediaPlayer"]; } @catch (__unused NSException *e) {}
    if (!self.primaryPlayer) return;
    if (!self.activeAudioPlayer && !self.fading) {
        NSInteger volume = [self audioVolumeForPlayer:self.primaryPlayer];
        if (volume > 0) self.desiredVolume = volume;
    }
    [self startTimerIfNeeded];
}

- (void)playbackStopped
{
    [self cancelFadeAndRestore:YES];
    [self stopTimer];
}

- (void)playbackPaused:(BOOL)paused
{
    self.paused = paused;
    if (paused) {
        [self invoke:self.activeAudioPlayer selector:@selector(pause)];
        [self invoke:self.preparedAudioPlayer selector:@selector(pause)];
        [self stopTimer];
    } else {
        [self invoke:self.activeAudioPlayer selector:@selector(play)];
        [self invoke:self.preparedAudioPlayer selector:@selector(play)];
        [self startTimerIfNeeded];
    }
}

- (void)manualNavigation
{
    [self cancelFadeAndRestore:YES];
    self.inTransition = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self.inTransition = NO; [self playbackStarted]; });
}

- (void)positionChanged
{
    if (self.fading) [self cancelFadeAndRestore:YES];
    [self startTimerIfNeeded];
}

- (void)didMoveToNextMedia
{
    self.inTransition = NO;
    if (self.fading) {
        [self finishFadeAtTransition];
        return;
    }
    if (self.preparedAudioPlayer) {
        [self setAudioVolume:self.preparedAudioPlayer volume:self.desiredVolume];
        [self stopAndReleasePlayer:self.activeAudioPlayer];
        self.activeAudioPlayer = self.preparedAudioPlayer;
        self.preparedAudioPlayer = nil;
        [self setPrimaryMuted:YES];
        [self startTimerIfNeeded];
    } else if (self.activeAudioPlayer) {
        [self setAudioVolume:self.activeAudioPlayer volume:self.desiredVolume];
        [self setPrimaryMuted:YES];
        [self startTimerIfNeeded];
    } else {
        [self setPrimaryMuted:NO];
    }
}

- (void)userVolumeChanged:(NSInteger)volume
{
    if (self.internalVolumeChange) return;
    self.desiredVolume = MIN(MAX(volume, 0), 200);
    if (self.activeAudioPlayer) [self setAudioVolume:self.activeAudioPlayer volume:self.desiredVolume];
    if (self.preparedAudioPlayer && !self.fading) [self setAudioVolume:self.preparedAudioPlayer volume:0];
    if (self.activeAudioPlayer || self.preparedAudioPlayer || self.fading) [self setPrimaryMuted:YES];
}

- (void)startTimerIfNeeded
{
    if (self.paused || self.inTransition || self.timer || [self configuredDuration] <= 0.0) return;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.02 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)stopTimer
{
    [self.timer invalidate];
    self.timer = nil;
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    if (self.paused || self.inTransition || !self.service) return;
    NSTimeInterval duration = [self configuredDuration];
    if (duration <= 0.0) { [self cancelFadeAndRestore:YES]; [self stopTimer]; return; }
    if (!self.primaryPlayer) { [self playbackStarted]; return; }

    if (!self.fading) {
        if (self.activeAudioPlayer) {
            [self prepareAndStartNextFadeWhenReady:duration];
            return;
        }
        NSTimeInterval remaining = [self remainingWallClockTimeForPlayer:self.primaryPlayer];
        if (remaining > 0.0 && remaining <= duration) {
            id nextMedia = [self nextMediaForService:self.service];
            if (nextMedia) [self beginFadeToMedia:nextMedia duration:duration outgoing:self.primaryPlayer];
        }
        return;
    }

    NSTimeInterval remaining = [self remainingWallClockTimeForPlayer:self.fadeOutgoingPlayer];
    CGFloat progress = (CGFloat)MIN(MAX(1.0 - (remaining / self.fadeDuration), 0.0), 1.0);
    NSInteger outgoing = (NSInteger)llround((double)self.desiredVolume * (1.0 - progress));
    NSInteger incoming = (NSInteger)llround((double)self.desiredVolume * progress);
    [self setAudioVolume:self.fadeOutgoingPlayer volume:outgoing];
    [self setAudioVolume:self.fadeIncomingPlayer volume:incoming];
}

- (void)prepareAndStartNextFadeWhenReady:(NSTimeInterval)duration
{
    if (self.preparedAudioPlayer || self.fading) return;
    NSTimeInterval remaining = [self remainingWallClockTimeForPlayer:self.primaryPlayer];
    if (remaining <= 0.0 || remaining > duration) return;
    id nextMedia = [self nextMediaForService:self.service];
    if (nextMedia) [self beginFadeToMedia:nextMedia duration:duration outgoing:self.activeAudioPlayer];
}

- (void)beginFadeToMedia:(id)media duration:(NSTimeInterval)duration outgoing:(id)outgoing
{
    if (!media || !outgoing || self.fading) return;
    id incoming = [self createAudioOnlyPlayerForMedia:media];
    if (!incoming) return;
    self.fadeOutgoingPlayer = outgoing;
    self.fadeIncomingPlayer = incoming;
    self.preparedAudioPlayer = incoming;
    self.fadeDuration = duration;
    self.fadeStart = CACurrentMediaTime();
    self.fading = YES;
    [self setAudioVolume:incoming volume:0];
    [self setPrimaryMuted:YES];
}

- (void)finishFadeAtTransition
{
    id incoming = self.fadeIncomingPlayer;
    id outgoing = self.fadeOutgoingPlayer;
    [self setAudioVolume:outgoing volume:0];
    [self setAudioVolume:incoming volume:self.desiredVolume];
    [self stopAndReleasePlayer:outgoing];
    self.activeAudioPlayer = incoming;
    self.preparedAudioPlayer = nil;
    self.fadeOutgoingPlayer = nil;
    self.fadeIncomingPlayer = nil;
    self.fading = NO;
    [self setPrimaryMuted:YES];
}

- (void)finishFadeWithoutTransition
{
    id incoming = self.fadeIncomingPlayer;
    id outgoing = self.fadeOutgoingPlayer;
    [self setAudioVolume:outgoing volume:0];
    [self setAudioVolume:incoming volume:self.desiredVolume];
    [self stopAndReleasePlayer:outgoing];
    if (self.activeAudioPlayer == outgoing) self.activeAudioPlayer = incoming;
    self.preparedAudioPlayer = nil;
    self.fadeOutgoingPlayer = nil;
    self.fadeIncomingPlayer = nil;
    self.fading = NO;
    [self setPrimaryMuted:YES];
}

- (void)cancelFadeAndRestore:(BOOL)restorePrimary
{
    [self setAudioVolume:self.fadeIncomingPlayer volume:0];
    [self setAudioVolume:self.preparedAudioPlayer volume:0];
    if (restorePrimary) [self setPrimaryMuted:NO];
    [self stopAndReleasePlayer:self.preparedAudioPlayer];
    if (self.fading && self.fadeOutgoingPlayer != self.activeAudioPlayer) [self stopAndReleasePlayer:self.fadeOutgoingPlayer];
    self.preparedAudioPlayer = nil;
    self.fadeOutgoingPlayer = nil;
    self.fadeIncomingPlayer = nil;
    self.fading = NO;
}

- (id)nextMediaForService:(id)service
{
    @try {
        BOOL shuffle = [[service valueForKey:@"shuffleMode"] boolValue];
        id list = shuffle ? [service valueForKey:@"shuffledList"] : [service valueForKey:@"mediaList"];
        id current = [service valueForKey:@"currentlyPlayingMedia"];
        if (!list || !current) return nil;
        NSInteger count = [[list valueForKey:@"count"] integerValue];
        if (count <= 0) return nil;
        NSInteger (*indexOfMedia)(id, SEL, id) = (NSInteger (*)(id, SEL, id))objc_msgSend;
        NSInteger index = indexOfMedia(list, @selector(indexOfMedia:), current);
        if (index < 0) return nil;
        NSInteger repeatMode = [[service valueForKey:@"repeatMode"] integerValue];
        NSInteger nextIndex = -1;
        if (repeatMode == kVLCRepeatCurrentItem) nextIndex = index;
        else if (index + 1 < count) nextIndex = index + 1;
        else if (repeatMode == kVLCRepeatAllItems) nextIndex = 0;
        if (nextIndex < 0 || nextIndex >= count) return nil;
        id (*mediaAtIndex)(id, SEL, NSUInteger) = (id (*)(id, SEL, NSUInteger))objc_msgSend;
        return mediaAtIndex(list, @selector(mediaAtIndex:), (NSUInteger)nextIndex);
    } @catch (__unused NSException *exception) { return nil; }
}

- (id)createAudioOnlyPlayerForMedia:(id)media
{
    @try {
        Class playerClass = NSClassFromString(@"VLCMediaPlayer");
        if (!playerClass) return nil;
        id library = [self.primaryPlayer valueForKey:@"libraryInstance"];
        id player = nil;
        if (library) {
            id allocated = [playerClass alloc];
            id (*initWithLibrary)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            player = initWithLibrary(allocated, @selector(initWithLibrary:), library);
        }
        if (!player) player = [[playerClass alloc] init];
        if (!player) return nil;
        [player setValue:media forKey:@"media"];
        @try { [player setValue:@(-1) forKey:@"currentVideoTrackIndex"]; } @catch (__unused NSException *e) {}
        float rate = 1.0;
        @try { rate = [[self.primaryPlayer valueForKey:@"rate"] floatValue]; } @catch (__unused NSException *e) {}
        if (rate > 0.0) @try { [player setValue:@(rate) forKey:@"rate"]; } @catch (__unused NSException *e) {}
        [self setAudioVolume:player volume:0];
        [self invoke:player selector:@selector(play)];
        return player;
    } @catch (__unused NSException *exception) { return nil; }
}

- (NSTimeInterval)remainingWallClockTimeForPlayer:(id)player
{
    @try {
        id media = [player valueForKey:@"media"];
        id length = [media valueForKey:@"length"];
        id time = [player valueForKey:@"time"];
        double total = [length doubleValue] / 1000.0;
        double current = [time doubleValue] / 1000.0;
        float rate = [[player valueForKey:@"rate"] floatValue];
        if (rate <= 0.0) rate = 1.0;
        if (total <= 0.0 || current < 0.0 || current > total) return DBL_MAX;
        return MAX(0.0, (total - current) / rate);
    } @catch (__unused NSException *exception) { return DBL_MAX; }
}

- (NSInteger)audioVolumeForPlayer:(id)player
{
    if (!player) return self.desiredVolume;
    @try {
        id audio = [player valueForKey:@"audio"];
        return MIN(MAX([[audio valueForKey:@"volume"] integerValue], 0), 200);
    } @catch (__unused NSException *exception) { return self.desiredVolume; }
}

- (void)setAudioVolume:(id)player volume:(NSInteger)volume
{
    if (!player) return;
    @try {
        id audio = [player valueForKey:@"audio"];
        self.internalVolumeChange = YES;
        [audio setValue:@(MIN(MAX(volume, 0), 200)) forKey:@"volume"];
        self.internalVolumeChange = NO;
    } @catch (__unused NSException *exception) { self.internalVolumeChange = NO; }
}

- (void)setPrimaryMuted:(BOOL)muted
{
    if (!self.primaryPlayer) return;
    [self setAudioVolume:self.primaryPlayer volume:muted ? 0 : self.desiredVolume];
}

- (void)stopAndReleasePlayer:(id)player
{
    if (player) [self invoke:player selector:@selector(stop)];
}

- (void)invoke:(id)object selector:(SEL)selector
{
    if (!object || ![object respondsToSelector:selector]) return;
    void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    sendVoid(object, selector);
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self configuredDuration] <= 0.0) [self cancelFadeAndRestore:YES];
        else [self startTimerIfNeeded];
    });
}

- (void)audioInterruption:(NSNotification *)notification
{
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (!type) return;
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) [self playbackPaused:YES];
    else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) [self playbackPaused:NO];
}

- (void)routeChanged:(NSNotification *)notification
{
    (void)notification;
    if (self.fading) [self cancelFadeAndRestore:YES];
}

@end
