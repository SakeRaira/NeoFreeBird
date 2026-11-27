//
//  DebugSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/DebugSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"

#ifndef NFB_BUILD_DATE_STRING
#define NFB_BUILD_DATE_STRING ""
#endif

extern void applySensitiveHighlightSetting(void);

// When the tweak in this IPA was compiled (the IPA's build, in this
// device's time zone) and the commit it came from.
static NSString* BuildInfoText(void) {
    NSString* stamp = @NFB_BUILD_DATE_STRING;
    NSString* when = stamp.length > 0 ? stamp : @"?";
    NSDate* date = stamp.length > 0 ? [[[NSISO8601DateFormatter alloc] init] dateFromString:stamp] : nil;
    if (date) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = NSTimeZone.localTimeZone;
        formatter.dateFormat = @"yyyy/MM/dd HH:mm";
        when = [formatter stringFromDate:date];
    }
    return [NSString stringWithFormat:@"%@ (%@)", when, @NFB_COMMIT_STRING];
}

@implementation DebugSettingsViewController

- (NSString*)pageKey {
    return @"debug";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:[ModernSettingsCompactButtonCell class] forCellReuseIdentifier:@"BuildInfoCell"];
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* entry = self.visibleToggles[indexPath.row];
    if (![entry[@"type"] isEqualToString:@"buildInfo"]) {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    }
    ModernSettingsCompactButtonCell* cell = [tableView dequeueReusableCellWithIdentifier:@"BuildInfoCell"
                                                                            forIndexPath:indexPath];
    [cell configureWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:entry[@"titleKey"]]
                    subtitle:BuildInfoText()];
    cell.chevronImageView.hidden = YES;
    return cell;
}

// Tapping the build row copies it, for reports.
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* entry = self.visibleToggles[indexPath.row];
    if (![entry[@"type"] isEqualToString:@"buildInfo"]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIPasteboard.generalPasteboard.string = BuildInfoText();
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
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
