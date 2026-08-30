#import <Foundation/Foundation.h>

@interface CrossfadeController : NSObject
+ (instancetype)sharedController;
- (void)attachToPlaybackService:(id)service;
- (void)detach;
- (void)playbackStarted;
- (void)playbackStopped;
- (void)playbackPaused:(BOOL)paused;
- (void)manualNavigation;
- (void)positionChanged;
- (void)didMoveToNextMedia;
- (void)userVolumeChanged:(NSInteger)volume;
@end
