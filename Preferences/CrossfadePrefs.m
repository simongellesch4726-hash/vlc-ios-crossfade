#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Foundation/Foundation.h>

static NSString * const kCrossfadeDefaultsSuite = @"org.videolan.vlc-ios";
static NSString * const kCrossfadeDurationKey = @"CrossfadeDuration";

@interface CrossfadePrefsListController : PSListController
@end

@implementation CrossfadePrefsListController

+ (void)load
{
    NSLog(@"[CrossfadePrefs] +load: preference bundle loaded");
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSLog(@"[CrossfadePrefs] init: controller created; bundle=%@", [NSBundle bundleForClass:self.class].bundlePath);
    }
    return self;
}

- (NSArray *)specifiers
{
    if (_specifiers)
        return _specifiers;

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *rootPath = [bundle pathForResource:@"Root" ofType:@"plist"];
    NSDictionary *root = rootPath.length ? [NSDictionary dictionaryWithContentsOfFile:rootPath] : nil;

    NSLog(@"[CrossfadePrefs] specifiers: bundle=%@", bundle.bundlePath);
    NSLog(@"[CrossfadePrefs] specifiers: executable=%@", bundle.infoDictionary[@"CFBundleExecutable"]);
    NSLog(@"[CrossfadePrefs] specifiers: principalClass=%@", bundle.infoDictionary[@"NSPrincipalClass"]);
    NSLog(@"[CrossfadePrefs] specifiers: Root.plist=%@ exists=%@", rootPath, rootPath.length && [[NSFileManager defaultManager] fileExistsAtPath:rootPath] ? @"YES" : @"NO");
    NSLog(@"[CrossfadePrefs] specifiers: Root keys=%@", root.allKeys);

    NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
    NSLog(@"[CrossfadePrefs] specifiers: loadSpecifiersFromPlistName returned %@ specifiers", @(loaded.count));

    if (loaded.count > 0) {
        _specifiers = [loaded mutableCopy];
        self.title = @"Audio Crossfade";
        return _specifiers;
    }

    NSLog(@"[CrossfadePrefs] ERROR: Root.plist produced no specifiers; using programmatic fallback");
    _specifiers = [[self fallbackSpecifiers] mutableCopy];
    return _specifiers;
}

- (NSArray *)fallbackSpecifiers
{
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@""
                                                          target:self
                                                             set:nil
                                                             get:nil
                                                          detail:nil
                                                            cell:PSGroupCell
                                                            edit:nil];
    [group setProperty:@"Audio-only overlap between consecutive VLC playlist items. 0 seconds disables crossfade." forKey:@"footerText"];
    [specifiers addObject:group];

    NSArray *titles = @[
        @"Off", @"1 second", @"2 seconds", @"3 seconds",
        @"4 seconds", @"5 seconds", @"6 seconds", @"7 seconds",
        @"8 seconds", @"9 seconds", @"10 seconds", @"11 seconds",
        @"12 seconds", @"13 seconds", @"14 seconds", @"15 seconds"
    ];

    NSArray *values = @[
        @0, @1, @2, @3, @4, @5, @6, @7,
        @8, @9, @10, @11, @12, @13, @14, @15
    ];

    PSSpecifier *crossfade = [PSSpecifier preferenceSpecifierNamed:@"Audio Crossfade"
                                                              target:self
                                                                  set:@selector(setPreferenceValue:specifier:)
                                                                  get:@selector(readPreferenceValue:specifier:)
                                                               detail:NSClassFromString(@"PSListItemsController")
                                                                 cell:PSLinkListCell
                                                                 edit:nil];
    [crossfade setProperty:kCrossfadeDefaultsSuite forKey:@"defaults"];
    [crossfade setProperty:kCrossfadeDurationKey forKey:@"key"];
    [crossfade setProperty:@0 forKey:@"default"];
    [crossfade setProperty:titles forKey:@"validTitles"];
    [crossfade setProperty:values forKey:@"validValues"];
    [specifiers addObject:crossfade];

    self.title = @"Audio Crossfade";
    NSLog(@"[CrossfadePrefs] fallback: generated %@ specifiers", @(specifiers.count));
    return specifiers;
}

@end
