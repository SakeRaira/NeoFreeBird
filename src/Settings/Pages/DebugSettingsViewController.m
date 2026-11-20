//
//  DebugSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/DebugSettingsViewController.h"
#import "Headers/TWHeaders.h"

extern void applySensitiveHighlightSetting(void);

@implementation DebugSettingsViewController

- (NSString*)pageKey {
    return @"debug";
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"flex_twitter"]) {
        if (sender.isOn) {
            [[objc_getClass("FLEXManager") sharedManager] showExplorer];
        } else {
            [[objc_getClass("FLEXManager") sharedManager] hideExplorer];
        }
    } else if ([key isEqualToString:@"highlight_sensitive_tweets_debug"]) {
        applySensitiveHighlightSetting();
    }
}

@end
