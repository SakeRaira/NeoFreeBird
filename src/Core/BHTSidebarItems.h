//
//  BHTSidebarItems.h
//  NeoFreeBird
//
//  Which panels the side drawer lists. X's drawer has a row for every panel
//  that isn't on the tab bar; a panel hidden here is reported to it as being
//  on the tab bar, the same way NeoFreeBird already keeps some panels out
//  (FeatureSwitches.x).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The Grok panel, which the older "Hide Grok in sidebar" option controls.
extern const long long BHTSidebarGrokPanelID;

@interface BHTSidebarItems : NSObject

// Panels the drawer can show, in the drawer's usual order. Ones NeoFreeBird
// always keeps out of the drawer are left out.
@property (class, nonatomic, readonly) NSArray<NSNumber*>* candidatePanelIDs;

// Panels hidden by the user.
@property (class, nonatomic, readonly) NSArray<NSNumber*>* hiddenPanelIDs;

// The panels on the tab bar when the drawer last asked; they have no row in
// the drawer while they stay there.
@property (class, nonatomic, copy) NSArray<NSNumber*>* tabBarPanelIDs;

+ (BOOL)isPanelHidden:(long long)panelID;
+ (void)setPanel:(long long)panelID hidden:(BOOL)hidden;
+ (void)showAllPanels;

// X's own name for a panel, or nil.
+ (nullable NSString*)nameForPanelID:(long long)panelID;

@end

NS_ASSUME_NONNULL_END
