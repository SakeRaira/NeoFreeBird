//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Headers/TWHeaders.h"
#import "Settings/Pages/NGWordsViewController.h"

extern void applyHideCustomTimelinesSetting(void);

@implementation TimelinesSettingsViewController

- (NSString*)pageKey {
    return @"timelines";
}

// The NG words row's subtitle summarizes what was set on its own page.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)showNGWords:(NSDictionary*)sender {
    NGWordsViewController* words = [[NGWordsViewController alloc] initWithAccount:self.account];
    [self.navigationController pushViewController:words animated:YES];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    }
}

@end
