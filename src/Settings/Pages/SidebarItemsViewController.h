//
//  SidebarItemsViewController.h
//  NeoFreeBird
//
//  Chooses which panels the side drawer lists (BHTSidebarItems).
//

#import <UIKit/UIKit.h>

@class TFNTwitterAccount;

@interface SidebarItemsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithAccount:(TFNTwitterAccount*)account;

@end
