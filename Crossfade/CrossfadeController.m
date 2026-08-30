#import "CrossfadeController.h"
#import "CrossfadeAudioMixer.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <math.h>

static NSString * const kDurationKey = @"CrossfadeDuration";
static const NSInteger kRepeatCurrent = 1;
static const NSInteger kRepeatAll = 2;

@interface CrossfadeController ()
@property(nonatomic,weak) id service;
@property(nonatomic,strong) id servicePlayer;
@property(nonatomic,strong) id currentAudioPlayer;
@property(nonatomic,strong) id nextAudioPlayer;
@property(nonatomic,strong) id currentMedia;
@property(nonatomic,strong) id nextMediaObject;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL currentUsesPrimarySlot;
@property(nonatomic) BOOL fading;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL internalVolume;
@property(nonatomic) BOOL serviceAudioMuted;
@property(nonatomic) NSInteger volume;
@property(nonatomic) NSTimeInterval fadeDuration;
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
    self.servicePlayer = [self playerForService];
    self.volume = [self volumeOfPlayer:self.servicePlayer];
    if ([self duration] <= 0.0) {
        [self restoreServiceAudio];
        return;
    }
    [self muteServiceAudio];
    [self startTimer];
}

- (void)detach
{
    [self cancelTransition:YES];
    [self stopTimer];
    [self restoreServiceAudio];
    self.service = nil;
    self.servicePlayer = nil;
}

- (void)playbackStarted
{
    self.servicePlayer = [self playerForService];
    if ([self duration] <= 0.0) {
        [self cancelTransition:YES];
        [self restoreServiceAudio];
        return;
    }

    [self muteServiceAudio];
    id serviceMedia = [self mediaOfPlayer:self.servicePlayer];

    if (!self.currentAudioPlayer || ![self media:self.currentAudioPlayer isEqualTo:serviceMedia]) {
        [self cancelTransition:YES];
        [self startCurrentAudioFromServicePosition];
    } else {
        [self syncCurrentAudioToService];
    }
    [self startTimer];
}

- (void)playbackStopped
{
    [self cancelTransition:YES];
    [self stopTimer];
    [self restoreServiceAudio];
}

- (void)playbackPaused:(BOOL)paused
{
    self.paused = paused;
    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];

    if (paused) {
        [self call:self.currentAudioPlayer sel:@selector(pause)];
        [self call:self.nextAudioPlayer sel:@selector(pause)];
        [mixer setPrimaryActive:NO];
        [mixer setIncomingActive:NO];
        [self stopTimer];
    } else {
        [self call:self.currentAudioPlayer sel:@selector(play)];
        [self call:self.nextAudioPlayer sel:@selector(play)];
        [mixer setPrimaryActive:self.currentUsesPrimarySlot];
        [mixer setIncomingActive:!self.currentUsesPrimarySlot];
        [self syncCurrentAudioToService];
        [self startTimer];
    }
}

- (void)manualNavigation
{
    [self cancelTransition:YES];
    dispatch_async(dispatch_get_main_queue(), ^{ [self playbackStarted]; });
}

- (void)positionChanged
{
    if ([self duration] <= 0.0)
        return;
    [self cancelTransition:YES];
    [self syncCurrentAudioToService];
    [self startTimer];
}

- (void)userVolumeChanged:(NSInteger)value
{
    if (self.internalVolume)
        return;
    self.volume = MIN(MAX(value, 0), 200);
    if ([self duration] <= 0.0) {
        [self restoreServiceAudio];
        return;
    }
    [self muteServiceAudio];
    if (!self.fading) {
        if (self.currentUsesPrimarySlot)
            [[CrossfadeAudioMixer sharedMixer] setPrimaryGain:[self gainForVolume:self.volume]];
        else
            [[CrossfadeAudioMixer sharedMixer] setIncomingGain:[self gainForVolume:self.volume]];
    }
}

- (float)gainForVolume:(NSInteger)value
{
    return MIN(MAX((float)value / 100.0f, 0.0f), 2.0f);
}

- (void)startTimer
{
    if (self.timer || self.paused || !self.currentAudioPlayer || [self duration] <= 0.0)
        return;
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
    if (self.paused || !self.currentAudioPlayer || !self.service)
        return;

    NSTimeInterval configured = [self duration];
    if (configured <= 0.0) {
        [self cancelTransition:YES];
        [self restoreServiceAudio];
        [self stopTimer];
        return;
    }

    if (!self.fading) {
        NSTimeInterval remaining = [self remainingTime:self.currentAudioPlayer];
        if (remaining > 0.0 && remaining <= configured) {
            id media = [self nextMedia];
            if (media)
                [self beginFadeToMedia:media duration:MIN(configured, remaining)];
        }
        return;
    }

    NSTimeInterval remaining = [self remainingTime:self.currentAudioPlayer];
    CGFloat progress = self.fadeDuration > 0.0 ? (CGFloat)MIN(MAX(1.0 - remaining / self.fadeDuration, 0.0), 1.0) : 1.0;
    CGFloat theta = progress * (CGFloat)M_PI_2;
    float gain = [self gainForVolume:self.volume];
    float outgoing = gain * cosf(theta);
    float incoming = gain * sinf(theta);

    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];
    if (self.currentUsesPrimarySlot) {
        [mixer setPrimaryGain:outgoing];
        [mixer setIncomingGain:incoming];
    } else {
        [mixer setIncomingGain:outgoing];
        [mixer setPrimaryGain:incoming];
    }

    if (progress >= 1.0)
        [self finishFade];
}

- (void)beginFadeToMedia:(id)media duration:(NSTimeInterval)duration
{
    if (self.fading || !media || !self.currentAudioPlayer)
        return;

    id next = [self makeAudioPlayerForMedia:media];
    if (!next)
        return;

    BOOL nextPrimary = !self.currentUsesPrimarySlot;
    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];
    BOOL prepared = nextPrimary ? [mixer preparePrimaryPlayer:next] : [mixer prepareIncomingPlayer:next];
    if (!prepared) {
        [self call:next sel:@selector(stop)];
        return;
    }

    self.nextAudioPlayer = next;
    self.nextMediaObject = media;
    self.fadeDuration = MAX(duration, 0.02);
    self.fading = YES;

    if (nextPrimary) {
        [mixer setPrimaryActive:YES];
        [mixer setPrimaryGain:0.0];
    } else {
        [mixer setIncomingActive:YES];
        [mixer setIncomingGain:0.0];
    }

    [self call:next sel:@selector(play)];
}

- (void)finishFade
{
    if (!self.fading || !self.nextAudioPlayer)
        return;

    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];
    id oldPlayer = self.currentAudioPlayer;
    id newPlayer = self.nextAudioPlayer;
    BOOL newPrimary = !self.currentUsesPrimarySlot;
    float gain = [self gainForVolume:self.volume];

    if (self.currentUsesPrimarySlot) {
        [mixer setPrimaryGain:0.0];
        [mixer setIncomingGain:gain];
        [mixer stopPrimaryPlayer:oldPlayer];
    } else {
        [mixer setIncomingGain:0.0];
        [mixer setPrimaryGain:gain];
        [mixer stopIncomingPlayer:oldPlayer];
    }

    self.currentAudioPlayer = newPlayer;
    self.currentMedia = self.nextMediaObject;
    self.nextAudioPlayer = nil;
    self.nextMediaObject = nil;
    self.currentUsesPrimarySlot = newPrimary;
    self.fading = NO;
    self.fadeDuration = 0.0;
}

- (void)cancelTransition:(BOOL)restore
{
    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];

    if (self.nextAudioPlayer) {
        if (self.currentUsesPrimarySlot)
            [mixer stopIncomingPlayer:self.nextAudioPlayer];
        else
            [mixer stopPrimaryPlayer:self.nextAudioPlayer];
    }

    if (self.currentAudioPlayer) {
        float gain = restore ? [self gainForVolume:self.volume] : 0.0;
        if (self.currentUsesPrimarySlot) {
            [mixer setPrimaryActive:YES];
            [mixer setPrimaryGain:gain];
        } else {
            [mixer setIncomingActive:YES];
            [mixer setIncomingGain:gain];
        }
    }

    self.nextAudioPlayer = nil;
    self.nextMediaObject = nil;
    self.fading = NO;
    self.fadeDuration = 0.0;
}

- (void)startCurrentAudioFromServicePosition
{
    id media = [self mediaOfPlayer:self.servicePlayer];
    if (!media)
        return;

    id player = [self makeAudioPlayerForMedia:media];
    if (!player)
        return;

    CrossfadeAudioMixer *mixer = [CrossfadeAudioMixer sharedMixer];
    if (![mixer attachPrimaryPlayer:player]) {
        [self call:player sel:@selector(stop)];
        return;
    }

    self.currentUsesPrimarySlot = YES;
    self.currentAudioPlayer = player;
    self.currentMedia = media;
    self.fading = NO;

    [mixer setPrimaryActive:YES];
    [mixer setPrimaryGain:[self gainForVolume:self.volume]];
    [mixer setIncomingGain:0.0];
    [self call:player sel:@selector(play)];

    dispatch_async(dispatch_get_main_queue(), ^{ [self syncCurrentAudioToService]; });
}

- (void)syncCurrentAudioToService
{
    if (!self.currentAudioPlayer || !self.servicePlayer)
        return;
    NSTimeInterval time = [self currentTime:self.servicePlayer];
    if (time >= 0.0)
        [self setTime:time player:self.currentAudioPlayer];
}

- (id)playerForService
{
    id player = nil;
    @try { player = [self.service valueForKey:@"_mediaPlayer"]; } @catch (__unused NSException *exception) {}
    if (!player) {
        @try { player = [self.service valueForKey:@"mediaPlayer"]; } @catch (__unused NSException *exception) {}
    }
    return player;
}

- (id)mediaOfPlayer:(id)player
{
    if (!player)
        return nil;
    @try { return [player valueForKey:@"media"]; } @catch (__unused NSException *exception) { return nil; }
}

- (BOOL)media:(id)player isEqualTo:(id)media
{
    id a = [self mediaOfPlayer:player];
    if (!a || !media)
        return NO;
    if (a == media)
        return YES;
    @try { return [a isEqual:media]; } @catch (__unused NSException *exception) { return NO; }
}

- (NSTimeInterval)currentTime:(id)player
{
    @try {
        id time = [player valueForKey:@"time"];
        return [[time valueForKey:@"value"] doubleValue] / 1000.0;
    } @catch (__unused NSException *exception) { return -1.0; }
}

- (NSTimeInterval)remainingTime:(id)player
{
    @try {
        id time = [player valueForKey:@"remainingTime"];
        return [[time valueForKey:@"value"] doubleValue] / 1000.0;
    } @catch (__unused NSException *exception) { return -1.0; }
}

- (void)setTime:(NSTimeInterval)time player:(id)player
{
    if (!player || time < 0.0)
        return;
    @try {
        Class timeClass = NSClassFromString(@"VLCTime");
        if (timeClass) {
            id value = [[timeClass alloc] initWithInt:(int)llround(time * 1000.0)];
            [player setValue:value forKey:@"time"];
        }
    } @catch (__unused NSException *exception) {}
}

- (NSInteger)volumeOfPlayer:(id)player
{
    if (!player)
        return 100;
    @try {
        id audio = [player valueForKey:@"audio"];
        return MAX(0, [[audio valueForKey:@"volume"] integerValue]);
    } @catch (__unused NSException *exception) { return 100; }
}

- (void)muteServiceAudio
{
    if (!self.servicePlayer || self.serviceAudioMuted)
        return;
    self.volume = [self volumeOfPlayer:self.servicePlayer];
    self.internalVolume = YES;
    @try {
        id audio = [self.servicePlayer valueForKey:@"audio"];
        [audio setValue:@0 forKey:@"volume"];
    } @catch (__unused NSException *exception) {}
    self.internalVolume = NO;
    self.serviceAudioMuted = YES;
}

- (void)restoreServiceAudio
{
    if (!self.servicePlayer || !self.serviceAudioMuted)
        return;
    self.internalVolume = YES;
    @try {
        id audio = [self.servicePlayer valueForKey:@"audio"];
        [audio setValue:@(self.volume) forKey:@"volume"];
    } @catch (__unused NSException *exception) {}
    self.internalVolume = NO;
    self.serviceAudioMuted = NO;
}

- (id)makeAudioPlayerForMedia:(id)media
{
    @try {
        Class playerClass = NSClassFromString(@"VLCMediaPlayer");
        if (!playerClass || !media)
            return nil;

        id library = [self.servicePlayer valueForKey:@"libraryInstance"];
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
        @try { [player setValue:@(-1) forKey:@"currentVideoTrackIndex"]; } @catch (__unused NSException *exception) {}
        float rate = 1.0f;
        @try { rate = [[self.servicePlayer valueForKey:@"rate"] floatValue]; } @catch (__unused NSException *exception) {}
        if (rate > 0.0f)
            @try { [player setValue:@(rate) forKey:@"rate"]; } @catch (__unused NSException *exception) {}
        return player;
    } @catch (__unused NSException *exception) { return nil; }
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
        if (count <= 0)
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
        if (nextIndex < 0 || nextIndex >= count)
            return nil;
        id (*mediaAt)(id, SEL, NSUInteger) = (void *)objc_msgSend;
        return mediaAt(list, @selector(mediaAtIndex:), (NSUInteger)nextIndex);
    } @catch (__unused NSException *exception) { return nil; }
}

- (void)settingsChanged:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self duration] <= 0.0) {
            [self cancelTransition:YES];
            [self stopTimer];
            [self restoreServiceAudio];
        } else if (self.service) {
            [self muteServiceAudio];
            [self startTimer];
        }
    });
}

- (void)interruption:(NSNotification *)notification
{
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.integerValue == AVAudioSessionInterruptionTypeBegan)
        [self playbackPaused:YES];
    else
        [self playbackPaused:NO];
}

- (void)routeChanged:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self duration] > 0.0 && self.service)
            [self startTimer];
    });
}

- (void)call:(id)object sel:(SEL)selector
{
    if (!object || ![object respondsToSelector:selector])
        return;
    void (*message)(id, SEL) = (void *)objc_msgSend;
    message(object, selector);
}

@end
