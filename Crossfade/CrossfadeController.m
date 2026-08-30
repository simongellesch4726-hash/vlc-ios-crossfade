#import "CrossfadeController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <float.h>
#import <math.h>

static NSString * const kDurationKey = @"CrossfadeDuration";
static const NSInteger kRepeatCurrent = 1, kRepeatAll = 2;

@interface CrossfadeController ()
@property(nonatomic,weak) id service;
@property(nonatomic,strong) id primary, active, incoming;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL fading, paused, internalVolume;
@property(nonatomic) NSInteger volume;
@property(nonatomic) NSTimeInterval fadeDuration;
@property(nonatomic,strong) id outgoing;
@end

@implementation CrossfadeController
+ (instancetype)sharedController { static CrossfadeController *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
- (instancetype)init {
    if ((self=[super init])) {
        _volume=100;
        NSNotificationCenter *n=[NSNotificationCenter defaultCenter];
        [n addObserver:self selector:@selector(settingsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
        [n addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
        [n addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [self cancel:YES]; }
- (NSTimeInterval)duration { double d=[[NSUserDefaults standardUserDefaults] doubleForKey:kDurationKey]; return isfinite(d)?MIN(MAX(d,0),15):0; }
- (void)attachToPlaybackService:(id)s { self.service=s; if(!s)return; @try{self.primary=[s valueForKey:@"_mediaPlayer"];}@catch(__unused NSException*e){} if(!self.primary)@try{self.primary=[s valueForKey:@"mediaPlayer"];}@catch(__unused NSException*e){} NSInteger v=[self volumeOf:self.primary]; if(v>0)self.volume=v; [self startTimer]; }
- (void)detach { [self cancel:YES]; [self stopTimer]; self.service=nil; self.primary=nil; }
- (void)playbackStarted { if(self.service)@try{self.primary=[self.service valueForKey:@"_mediaPlayer"];}@catch(__unused NSException*e){} if(self.primary && !self.active && !self.fading){NSInteger v=[self volumeOf:self.primary];if(v>0)self.volume=v;} [self startTimer]; }
- (void)playbackStopped { [self cancel:YES]; [self stopTimer]; }
- (void)playbackPaused:(BOOL)p { self.paused=p; if(p){[self call:self.active sel:@selector(pause)];[self call:self.incoming sel:@selector(pause)];[self stopTimer];}else{[self call:self.active sel:@selector(play)];[self call:self.incoming sel:@selector(play)];[self startTimer];} }
- (void)manualNavigation { [self cancel:YES]; dispatch_async(dispatch_get_main_queue(),^{[self playbackStarted];}); }
- (void)positionChanged { if(self.fading)[self cancel:YES]; [self startTimer]; }
- (void)didMoveToNextMedia {
    if(self.fading){ [self setVolume:0 player:self.outgoing]; [self setVolume:self.volume player:self.incoming]; [self stop:self.outgoing]; self.active=self.incoming; self.incoming=nil; self.outgoing=nil; self.fading=NO; [self mutePrimary]; [self startTimer]; return; }
    if(self.incoming){ [self setVolume:self.volume player:self.incoming]; [self stop:self.active]; self.active=self.incoming; self.incoming=nil; [self mutePrimary]; [self startTimer]; }
    else if(self.active){ [self setVolume:self.volume player:self.active]; [self mutePrimary]; [self startTimer]; }
    else [self unmutePrimary];
}
- (void)userVolumeChanged:(NSInteger)v { if(self.internalVolume)return; self.volume=MIN(MAX(v,0),200); if(self.active)[self setVolume:self.volume player:self.active]; if(self.incoming && !self.fading)[self setVolume:0 player:self.incoming]; if(self.active||self.incoming||self.fading)[self mutePrimary]; }
- (void)startTimer { if(self.timer||self.paused||[self duration]<=0)return; self.timer=[NSTimer scheduledTimerWithTimeInterval:.02 target:self selector:@selector(tick:) userInfo:nil repeats:YES]; }
- (void)stopTimer { [self.timer invalidate]; self.timer=nil; }
- (void)tick:(NSTimer*)t {
    (void)t; if(self.paused||!self.service)return; NSTimeInterval d=[self duration]; if(d<=0){[self cancel:YES];[self stopTimer];return;} if(!self.primary){[self playbackStarted];return;}
    if(!self.fading){ id out=self.active?:self.primary; NSTimeInterval r=[self remaining:out]; if(r>0&&r<=d){id m=[self nextMedia];if(m)[self begin:m outgoing:out duration:d];} return; }
    NSTimeInterval r=[self remaining:self.outgoing]; CGFloat p=(CGFloat)MIN(MAX(1-r/self.fadeDuration,0),1); [self setVolume:(NSInteger)llround(self.volume*(1-p)) player:self.outgoing]; [self setVolume:(NSInteger)llround(self.volume*p) player:self.incoming];
}
- (id)nextMedia {
    @try{
        BOOL shuffle=[[self.service valueForKey:@"shuffleMode"] boolValue]; id list=shuffle?[self.service valueForKey:@"shuffledList"]:[self.service valueForKey:@"mediaList"]; id cur=[self.service valueForKey:@"currentlyPlayingMedia"]; if(!list||!cur)return nil; NSInteger count=[[list valueForKey:@"count"] integerValue]; if(count<1)return nil;
        NSInteger(*idx)(id,SEL,id)=(void*)objc_msgSend; NSInteger i=idx(list,@selector(indexOfMedia:),cur); if(i<0)return nil; NSInteger r=[[self.service valueForKey:@"repeatMode"] integerValue]; NSInteger n=-1; if(r==kRepeatCurrent)n=i; else if(i+1<count)n=i+1; else if(r==kRepeatAll)n=0; if(n<0)return nil; id(*at)(id,SEL,NSUInteger)=(void*)objc_msgSend; return at(list,@selector(mediaAtIndex:),(NSUInteger)n);
    }@catch(__unused NSException*e){return nil;}
}
- (void)begin:(id)media outgoing:(id)out duration:(NSTimeInterval)d {
    if(self.fading||!media||!out)return; id p=[self makePlayer:media]; if(!p)return; self.outgoing=out;self.incoming=p;self.fadeDuration=d;self.fading=YES;[self setVolume:0 player:p];[self mutePrimary];
}
- (id)makePlayer:(id)media {
    @try{
        Class c=NSClassFromString(@"VLCMediaPlayer"); if(!c)return nil; id lib=[self.primary valueForKey:@"libraryInstance"]; id p=nil; if(lib){id a=[c alloc];id(*initLib)(id,SEL,id)=(void*)objc_msgSend;p=initLib(a,@selector(initWithLibrary:),lib);} if(!p)p=[[c alloc]init]; if(!p)return nil; [p setValue:media forKey:@"media"]; @try{[p setValue:@(-1) forKey:@"currentVideoTrackIndex"];}@catch(__unused NSException*e){} @try{float rate=[[self.primary valueForKey:@"rate"]floatValue];if(rate>0)[p setValue:@(rate) forKey:@"rate"];}@catch(__unused NSException*e){} [self setVolume:0 player:p]; [self call:p sel:@selector(play)]; return p;
    }@catch(__unused NSException*e){return nil;}
}
- (NSTimeInterval)remaining:(id)p {
    @try{double total=[[[p valueForKey:@"media"]valueForKey:@"length"]doubleValue]/1000.;double now=[[p valueForKey:@"time"]doubleValue]/1000.;float rate=[[p valueForKey:@"rate"]floatValue];if(rate<=0)rate=1;if(total<=0||now<0||now>total)return DBL_MAX;return MAX(0,(total-now)/rate);}@catch(__unused NSException*e){return DBL_MAX;}
}
- (NSInteger)volumeOf:(id)p { if(!p)return self.volume; @try{return MIN(MAX([[[p valueForKey:@"audio"]valueForKey:@"volume"]integerValue],0),200);}@catch(__unused NSException*e){return self.volume;} }
- (void)setVolume:(NSInteger)v player:(id)p { if(!p)return;@try{self.internalVolume=YES;[[p valueForKey:@"audio"]setValue:@(MIN(MAX(v,0),200)) forKey:@"volume"];self.internalVolume=NO;}@catch(__unused NSException*e){self.internalVolume=NO;} }
- (void)mutePrimary { [self setVolume:0 player:self.primary]; }
- (void)unmutePrimary { [self setVolume:self.volume player:self.primary]; }
- (void)stop:(id)p { if(p)[self call:p sel:@selector(stop)]; }
- (void)call:(id)o sel:(SEL)s { if(o&&[o respondsToSelector:s]){void(*f)(id,SEL)=(void*)objc_msgSend;f(o,s);} }
- (void)cancel:(BOOL)restore { [self setVolume:0 player:self.incoming]; if(restore)[self unmutePrimary]; [self stop:self.incoming]; if(self.fading&&self.outgoing!=self.active)[self stop:self.outgoing]; self.incoming=nil;self.outgoing=nil;self.fading=NO; }
- (void)settingsChanged:(NSNotification*)n { (void)n; dispatch_async(dispatch_get_main_queue(),^{if([self duration]<=0)[self cancel:YES];else[self startTimer];}); }
- (void)interruption:(NSNotification*)n { NSNumber*t=n.userInfo[AVAudioSessionInterruptionTypeKey];if(t.unsignedIntegerValue==AVAudioSessionInterruptionTypeBegan)[self playbackPaused:YES];else if(t.unsignedIntegerValue==AVAudioSessionInterruptionTypeEnded)[self playbackPaused:NO]; }
- (void)routeChanged:(NSNotification*)n { (void)n;if(self.fading)[self cancel:YES]; }
@end
