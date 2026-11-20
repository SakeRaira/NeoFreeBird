//
//  TimelinesSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/TimelinesSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTTweetLog.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"
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

- (NSString*)labelForTweetLogLimit:(NSInteger)limit {
    return [NSString stringWithFormat:[[BHTBundle sharedBundle] localizedStringForKey:@"TWEET_LOG_LIMIT_FORMAT"],
                                      (long)limit];
}

// The log limit row shows its number, which the generic page can't render.
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* settingData = self.visibleToggles[indexPath.row];
    if ([settingData[@"key"] isEqualToString:BHTTweetLogLimitKey]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell" forIndexPath:indexPath];
        NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:settingData[@"titleKey"]];
        [cell configureWithTitle:title subtitle:[self labelForTweetLogLimit:BHTTweetLog.limit]];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)showTweetLogLimitPicker:(NSDictionary*)sender {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[bundle localizedStringForKey:@"TWEET_LOG_LIMIT_TITLE"]
                                            message:[bundle localizedStringForKey:@"TWEET_LOG_LIMIT_MESSAGE"]
                                     preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber* limit in BHTTweetLog.limitChoices) {
        [alert addAction:[UIAlertAction actionWithTitle:[self labelForTweetLogLimit:limit.integerValue]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [BHTTweetLog setLimit:limit.integerValue];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"hide_custom_timelines"]) {
        applyHideCustomTimelinesSetting();
    }
}

@end
