//
//  NGWordsViewController.h
//  NeoFreeBird
//
//  The NG word list (BHTNGWords): on/off and the words themselves.
//

#import <UIKit/UIKit.h>

@class TFNTwitterAccount;

@interface NGWordsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithAccount:(TFNTwitterAccount*)account;

@end
