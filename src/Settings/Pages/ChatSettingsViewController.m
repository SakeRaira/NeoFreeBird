//
//  ChatSettingsViewController.m
//  NeoFreeBird
//
//  Created by orionblur
//

#import "Settings/Pages/ChatSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"

// Defined in Chat.x: what the read receipt block hooked and how often it held
// a read marker back.
extern NSString* BHTReadReceiptsStatusDetail(void);

@implementation ChatSettingsViewController

- (NSString*)pageKey {
    return @"chat";
}

// The status row's subtitle is written by Chat.x while the app runs.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)showReadReceiptsStatus:(NSDictionary*)sender {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    NSString* summary = [[NSUserDefaults standardUserDefaults] stringForKey:@"no_dm_read_receipts_status"]
                            ?: [bundle localizedStringForKey:@"READ_RECEIPTS_STATUS_NOT_FOUND"];
    NSString* message = [NSString stringWithFormat:@"%@\n\n%@", summary, BHTReadReceiptsStatusDetail()];
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[bundle localizedStringForKey:@"READ_RECEIPTS_STATUS_TITLE"]
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"READ_RECEIPTS_STATUS_COPY"]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                UIPasteboard.generalPasteboard.string = message;
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
}

@end
