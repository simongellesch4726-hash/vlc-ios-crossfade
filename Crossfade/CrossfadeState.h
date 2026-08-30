#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

@interface CrossfadeState : NSObject
+ (instancetype)sharedState;
- (void)configure;
- (void)handlePlaybackService:(id)service;
- (BOOL)isEnabled;
- (NSTimeInterval)duration;
- (void)cancelFade;
@end
