#import <Foundation/Foundation.h>
#import "CrossfadeController.h"

%hook VLCPlaybackService
- (void)startPlayback { %orig; [[CrossfadeController sharedController] attachToPlaybackService:self]; [[CrossfadeController sharedController] playbackStarted]; }
- (void)stopPlayback { [[CrossfadeController sharedController] playbackStopped]; %orig; }
- (void)play { %orig; [[CrossfadeController sharedController] playbackPaused:NO]; }
- (void)pause { [[CrossfadeController sharedController] playbackPaused:YES]; %orig; }
- (BOOL)next { [[CrossfadeController sharedController] manualNavigation]; return %orig; }
- (BOOL)previous { [[CrossfadeController sharedController] manualNavigation]; return %orig; }
- (void)setPlaybackPosition:(float)position { [[CrossfadeController sharedController] positionChanged]; %orig; }
- (void)mediaListPlayer:(id)player nextMedia:(id)media { %orig; [[CrossfadeController sharedController] didMoveToNextMedia]; }
%end

%hook VLCAudio
- (void)setVolume:(int)volume { %orig; [[CrossfadeController sharedController] userVolumeChanged:volume]; }
%end
