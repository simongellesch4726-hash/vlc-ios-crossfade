#import <Preferences/PSListController.h>

@interface CrossfadePrefsListController : PSListController
@end

@implementation CrossfadePrefsListController
- (NSArray *)specifiers
{
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
@end
