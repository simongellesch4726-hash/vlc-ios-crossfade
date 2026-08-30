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
- (void)primaryReachedEnd;
- (void)primaryStateChanged;
- (void)userVolumeChanged:(NSInteger)volume;
@end
