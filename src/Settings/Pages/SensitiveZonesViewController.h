//
//  SensitiveZonesViewController.h
//  NeoFreeBird
//
//  The places where sensitive content warnings come back (BHTSensitiveZones):
//  on/off, range, current status and the list of places.
//

#import <UIKit/UIKit.h>

@class TFNTwitterAccount;

@interface SensitiveZonesViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

- (instancetype)initWithAccount:(TFNTwitterAccount*)account;

@end
