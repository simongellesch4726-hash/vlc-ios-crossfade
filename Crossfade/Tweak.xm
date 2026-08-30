#import <Foundation/Foundation.h>
#import "CrossfadeController.h"

%hook VLCPlaybackService
- (void)startPlayback {
    %orig;
    CrossfadeController *c = [CrossfadeController sharedController];
    [c attachToPlaybackService:self];
    [c playbackStarted];
}

- (void)stopPlayback {
    [[CrossfadeController sharedController] playbackStopped];
    %orig;
}

- (void)play {
    %orig;
    [[CrossfadeController sharedController] playbackPaused:NO];
}

- (void)pause {
    [[CrossfadeController sharedController] playbackPaused:YES];
    %orig;
}

- (BOOL)next {
    [[CrossfadeController sharedController] manualNavigation];
    return %orig;
}

- (BOOL)previous {
    [[CrossfadeController sharedController] manualNavigation];
    return %orig;
}

- (void)setPlaybackPosition:(float)position {
    [[CrossfadeController sharedController] positionChanged];
    %orig;
}

- (void)mediaPlayerStateChanged:(NSNotification *)notification {
    /* VLCMediaPlayerStateEnded is 3 in MobileVLCKit 3.x. Handle it before
     * VLCPlaybackService advances the list player so the secondary audio
     * player can remain the audio source while the primary player opens the
     * next item for normal video playback. */
    id player = nil;
    @try { player = [self valueForKey:@"_mediaPlayer"]; } @catch (__unused NSException *e) {}
    NSInteger state = -1;
    @try { state = [[player valueForKey:@"state"] integerValue]; } @catch (__unused NSException *e) {}
    if (state == 3)
        [[CrossfadeController sharedController] primaryReachedEnd];

    %orig;

    if (state == 3)
        [[CrossfadeController sharedController] primaryStateChanged];
}
%end

%hook VLCAudio
- (void)setVolume:(int)volume {
    %orig;
    [[CrossfadeController sharedController] userVolumeChanged:volume];
}
%end
