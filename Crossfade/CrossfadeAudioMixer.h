#import <Foundation/Foundation.h>

@interface CrossfadeAudioMixer : NSObject

+ (instancetype)sharedMixer;

- (BOOL)attachPrimaryPlayer:(id)player;
- (BOOL)preparePrimaryPlayer:(id)player;
- (BOOL)prepareIncomingPlayer:(id)player;

- (void)setPrimaryGain:(float)gain;
- (void)setIncomingGain:(float)gain;
- (void)setPrimaryActive:(BOOL)active;
- (void)setIncomingActive:(BOOL)active;

- (void)stopPrimaryPlayer:(id)player;
- (void)stopIncomingPlayer:(id)player;
- (void)detach;

@end
