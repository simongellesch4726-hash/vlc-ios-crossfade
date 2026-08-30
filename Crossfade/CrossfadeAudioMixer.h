#import <Foundation/Foundation.h>

@interface CrossfadeAudioMixer : NSObject

+ (instancetype)sharedMixer;

- (BOOL)attachPrimaryPlayer:(id)primary;
- (BOOL)prepareIncomingPlayer:(id)incoming;
- (void)setPrimaryGain:(float)gain;
- (void)setIncomingGain:(float)gain;
- (void)setPrimaryActive:(BOOL)active;
- (void)setIncomingActive:(BOOL)active;
- (void)stopIncomingPlayer:(id)incoming;
- (void)detach;

@end
