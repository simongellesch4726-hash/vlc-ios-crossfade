#import "CrossfadeController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>

static NSString * const kDurationKey = @"CrossfadeDuration";
static const NSInteger kRepeatCurrent = 1;
static const NSInteger kRepeatAll = 2;
static const NSTimeInterval kHandoffWindow = 0.35;

@interface CrossfadeController ()
@property(nonatomic,weak) id service;
@property(nonatomic,strong) id primary;
@property(nonatomic,strong) id incoming;
@property(nonatomic,strong) id outgoingMedia;
@property(nonatomic,strong) id incomingMedia;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSTimer *handoffTimer;
@property(nonatomic) BOOL fading;
@property(nonatomic) BOOL transitionPending;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL internalVolume;
@property(nonatomic) BOOL handoffFading;
@property(nonatomic) NSInteger volume;
@property(nonatomic) NSTimeInterval fadeDuration;
@property(nonatomic) NSTimeInterval handoffStart;
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
    [self cancel:YES];
}

- (NSTimeInterval)duration
{
    double value = [[NSUserDefaults standardUserDefaults] doubleForKey:kDurationKey];
    return isfinite(value) ? MIN(MAX(value, 0.0), 15.0) : 0.0;
}

- (void)attachToPlaybackService:(id)service
{
    self.service = service;
    if (!service)
        return;

    @try { self.primary = [service valueForKey:@"_mediaPlayer"]; }
    @catch (__unused NSException *exception) { self.primary = nil; }

    if (!self.primary) {
        @try { self.primary = [service valueForKey:@"mediaPlayer"]; }
        @catch (__unused NSException *exception) {}
    }

    NSInteger currentVolume = [self volumeOf:self.primary];
    if (currentVolume > 0)
        self.volume = currentVolume;

    [self startTimer];
}

- (void)detach
{
    [self cancel:YES];
    [self stopTimer];
    [self stopHandoffTimer];
    self.service = nil;
    self.primary = nil;
}

- (void)playbackStarted
{
    if (self.service) {
        @try { self.primary = [self.service valueForKey:@"_mediaPlayer"]; }
        @catch (__unused NSException *exception) {}
    }

    if (self.primary && !self.fading && !self.incoming) {
        NSInteger currentVolume = [self volumeOf:self.primary];
        if (currentVolume > 0)
            self.volume = currentVolume;
    }

    [self startTimer];
}

- (void)playbackStopped
{
    [self cancel:YES];
    [self stopTimer];
    [self stopHandoffTimer];
}

- (void)playbackPaused:(BOOL)paused
{
    self.paused = paused;

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
    [self cancel:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self playbackStarted];
    });
}

- (void)positionChanged
{
    if (self.fading || self.incoming)
        [self cancel:YES];
    [self startTimer];
}

- (void)primaryReachedEnd
{
    if (!self.fading || !self.incoming)
        return;

    self.transitionPending = YES;
    [self stopTimer];
}

- (void)primaryStateChanged
{
    if (!self.transitionPending || !self.incoming)
        return;

    [self startHandoffTimer];
}

- (void)userVolumeChanged:(NSInteger)value
{
    if (self.internalVolume)
        return;

    self.volume = MIN(MAX(value, 0), 200);

    if (self.incoming) {
        if (!self.handoffFading && self.transitionPending)
            [self setVolume:self.volume player:self.incoming];
    } else if (!self.fading) {
        [self setVolume:self.volume player:self.primary];
    }
}

- (void)startTimer
{
    if (self.timer || self.paused || [self duration] <= 0.0 || self.transitionPending)
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
    if (self.handoffTimer || self.paused || !self.incoming)
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

    if (self.paused || !self.service || self.transitionPending)
        return;

    NSTimeInterval duration = [self duration];
    if (duration <= 0.0) {
        [self cancel:YES];
        [self stopTimer];
        return;
    }

    if (!self.primary) {
        [self playbackStarted];
        return;
    }

    if (!self.fading) {
        id outgoing = self.primary;
        NSTimeInterval remaining = [self remaining:outgoing];
        if (remaining > 0.0 && remaining <= duration) {
            id next = [self nextMedia];
            if (next)
                [self begin:next outgoing:outgoing duration:duration];
        }
        return;
    }

    NSTimeInterval remaining = [self remaining:self.primary];
    CGFloat progress = (CGFloat)MIN(MAX(1.0 - remaining / self.fadeDuration, 0.0), 1.0);
    [self setVolume:(NSInteger)llround(self.volume * (1.0 - progress)) player:self.primary];
    [self setVolume:(NSInteger)llround(self.volume * progress) player:self.incoming];
}

- (void)handoffTick:(NSTimer *)timer
{
    (void)timer;

    if (self.paused || !self.incoming || !self.transitionPending || !self.primary)
        return;

    id primaryMedia = nil;
    @try { primaryMedia = [self.primary valueForKey:@"media"]; }
    @catch (__unused NSException *exception) {}

    if (!primaryMedia || !self.incomingMedia || [primaryMedia compare:self.incomingMedia] != NSOrderedSame)
        return;

    NSTimeInterval primaryTime = [self currentTime:self.primary];
    NSTimeInterval incomingTime = [self currentTime:self.incoming];
    if (primaryTime < 0.0 || incomingTime < 0.0)
        return;

    if (!self.handoffFading && fabs(primaryTime - incomingTime) <= kHandoffWindow) {
        self.handoffFading = YES;
        self.handoffStart = CFAbsoluteTimeGetCurrent();
    }

    if (!self.handoffFading)
        return;

    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.handoffStart;
    CGFloat progress = (CGFloat)MIN(MAX(elapsed / 0.25, 0.0), 1.0);
    [self setVolume:(NSInteger)llround(self.volume * progress) player:self.primary];
    [self setVolume:(NSInteger)llround(self.volume * (1.0 - progress)) player:self.incoming];

    if (progress >= 1.0) {
        [self stop:self.incoming];
        self.incoming = nil;
        self.incomingMedia = nil;
        self.outgoingMedia = nil;
        self.fading = NO;
        self.transitionPending = NO;
        self.handoffFading = NO;
        [self stopHandoffTimer];
        [self startTimer];
    }
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

- (void)begin:(id)media outgoing:(id)outgoing duration:(NSTimeInterval)duration
{
    if (self.fading || self.incoming || !media || !outgoing)
        return;

    id player = [self makePlayer:media];
    if (!player)
        return;

    @try { self.outgoingMedia = [outgoing valueForKey:@"media"]; }
    @catch (__unused NSException *exception) { self.outgoingMedia = nil; }
    self.incomingMedia = media;
    self.incoming = player;
    self.fadeDuration = duration;
    self.fading = YES;
    self.transitionPending = NO;
    self.handoffFading = NO;

    [self setVolume:0 player:player];
    [self mutePrimary];
    [self call:player sel:@selector(play)];
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
            id (*initWithLibrary)(id, SEL, id) = (void *)objc_msgSend;
            player = initWithLibrary(allocated, @selector(initWithLibrary:), library);
        }
        if (!player)
            player = [[playerClass alloc] init];
        if (!player)
            return nil;

        [player setValue:media forKey:@"media"];
        @try { [player setValue:@(-1) forKey:@"currentVideoTrackIndex"]; }
        @catch (__unused NSException *exception) {}

        float rate = 1.0;
        @try { rate = [[self.primary valueForKey:@"rate"] floatValue]; }
        @catch (__unused NSException *exception) {}
        if (rate > 0.0)
            [player setValue:@(rate) forKey:@"rate"];

        [self setVolume:0 player:player];
        return player;
    }
    @catch (__unused NSException *exception) {
        return nil;
    }
}

- (NSTimeInterval)remaining:(id)player
{
    @try {
        double total = [[[player valueForKey:@"media"] valueForKey:@"length"] doubleValue] / 1000.0;
        double current = [[player valueForKey:@"time"] doubleValue] / 1000.0;
        float rate = [[player valueForKey:@"rate"] floatValue];
        if (rate <= 0.0)
            rate = 1.0;
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

- (NSInteger)volumeOf:(id)player
{
    if (!player)
        return self.volume;

    @try {
        return MIN(MAX([[[player valueForKey:@"audio"] valueForKey:@"volume"] integerValue], 0), 200);
    }
    @catch (__unused NSException *exception) {
        return self.volume;
    }
}

- (void)setVolume:(NSInteger)value player:(id)player
{
    if (!player)
        return;

    @try {
        self.internalVolume = YES;
        [[player valueForKey:@"audio"] setValue:@(MIN(MAX(value, 0), 200)) forKey:@"volume"];
        self.internalVolume = NO;
    }
    @catch (__unused NSException *exception) {
        self.internalVolume = NO;
    }
}

- (void)mutePrimary
{
    [self setVolume:0 player:self.primary];
}

- (void)unmutePrimary
{
    [self setVolume:self.volume player:self.primary];
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

- (void)cancel:(BOOL)restore
{
    [self stopHandoffTimer];
    [self setVolume:0 player:self.incoming];
    [self stop:self.incoming];

    self.incoming = nil;
    self.incomingMedia = nil;
    self.outgoingMedia = nil;
    self.fading = NO;
    self.transitionPending = NO;
    self.handoffFading = NO;

    if (restore)
        [self unmutePrimary];
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self duration] <= 0.0)
            [self cancel:YES];
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
    if (self.fading || self.incoming)
        [self cancel:YES];
}

@end
