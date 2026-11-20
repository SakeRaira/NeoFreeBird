//
//  BHTSidebarItems.m
//  NeoFreeBird
//

#import "Core/BHTSidebarItems.h"
#import "Core/BHTSettings.h"
#import <objc/message.h>
#import <objc/runtime.h>

const long long BHTSidebarGrokPanelID = 14;

static NSString* const kHiddenPanelsKey = @"sidebar_hidden_panels";
static NSString* const kHideGrokSidebarKey = @"hide_grok_sidebar";

// Defined in FeatureSwitches.x.
extern BOOL BHTSidebarPanelIsForcedHidden(long long panelID);

static NSArray<NSNumber*>* TabBarPanelIDs;

@implementation BHTSidebarItems

// Each panel's navigation controller knows its panel ID. Asking them keeps
// arbitrary numbers away from T1PanelIdentity.
+ (NSArray<NSNumber*>*)candidatePanelIDs {
    static NSArray<NSString*>* classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classNames = @[
            @"_TtC14T1TwitterSwift27ProfileNavigationController",
            @"_TtC14T1TwitterSwift30PremiumHubNavigationController",
            @"_TtC14T1TwitterSwift27XChatDMNavigationController",
            @"_TtC14T1TwitterSwift25ListsNavigationController",
            @"_TtC14T1TwitterSwift29BookmarksNavigationController",
            @"_TtC14T1TwitterSwift36T1CommunitiesTabNavigationController",
            @"_TtC14T1TwitterSwift24JobsNavigationController",
            @"_TtC14T1TwitterSwift24GrokNavigationController",
            @"_TtC14T1TwitterSwift35ActivityHistoryNavigationController",
            @"_TtC14T1TwitterSwift27ConnectNavigationController",
            @"_TtC14T1TwitterSwift25BoostNavigationController",
            @"_TtC14T1TwitterSwift32OfflineCacheNavigationController",
            @"_TtC14T1TwitterSwift33NotificationsNavigationController",
            @"T1GuideNavigationController",
        ];
    });

    NSMutableOrderedSet<NSNumber*>* panelIDs = [NSMutableOrderedSet orderedSet];
    for (NSString* className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        Method method = cls ? class_getClassMethod(cls, @selector(panelID)) : NULL;
        const char* encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || (encoding[0] != 'q' && encoding[0] != 'l')) {
            continue;
        }
        [panelIDs addObject:@(((long long (*)(id, SEL))objc_msgSend)(cls, @selector(panelID)))];
    }
    // Community Notes has no navigation controller of its own.
    [panelIDs addObject:@13];

    // Leaves out what never reaches the drawer anyway (FeatureSwitches.x).
    NSMutableArray<NSNumber*>* candidates = [NSMutableArray array];
    for (NSNumber* panelID in panelIDs) {
        long long value = panelID.longLongValue;
        if (BHTSidebarPanelIsForcedHidden(value) || [self nameForPanelID:value].length == 0) {
            continue;
        }
        [candidates addObject:panelID];
    }
    return candidates;
}

+ (NSArray<NSNumber*>*)hiddenPanelIDs {
    NSMutableArray<NSNumber*>* hidden = [NSMutableArray array];
    for (id value in [NSUserDefaults.standardUserDefaults arrayForKey:kHiddenPanelsKey]) {
        if ([value isKindOfClass:NSNumber.class] && [value longLongValue] != BHTSidebarGrokPanelID) {
            [hidden addObject:value];
        }
    }
    // Grok's row is the older option's.
    if ([self isPanelHidden:BHTSidebarGrokPanelID]) {
        [hidden addObject:@(BHTSidebarGrokPanelID)];
    }
    return hidden;
}

+ (NSArray<NSNumber*>*)tabBarPanelIDs {
    return TabBarPanelIDs ?: @[];
}

+ (void)setTabBarPanelIDs:(NSArray<NSNumber*>*)panelIDs {
    TabBarPanelIDs = [panelIDs copy];
}

+ (BOOL)isPanelHidden:(long long)panelID {
    if (panelID == BHTSidebarGrokPanelID) {
        return [BHTSettings boolForKey:kHideGrokSidebarKey];
    }
    return [[NSUserDefaults.standardUserDefaults arrayForKey:kHiddenPanelsKey] containsObject:@(panelID)];
}

+ (void)setPanel:(long long)panelID hidden:(BOOL)hidden {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (panelID == BHTSidebarGrokPanelID) {
        [defaults setBool:hidden forKey:kHideGrokSidebarKey];
        return;
    }

    NSMutableArray* stored = [[defaults arrayForKey:kHiddenPanelsKey] mutableCopy] ?: [NSMutableArray array];
    [stored removeObject:@(panelID)];
    if (hidden) {
        [stored addObject:@(panelID)];
    }
    [defaults setObject:stored forKey:kHiddenPanelsKey];
}

+ (void)showAllPanels {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kHiddenPanelsKey];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kHideGrokSidebarKey];
}

+ (NSString*)nameForPanelID:(long long)panelID {
    Class identity = objc_getClass("T1PanelIdentity");
    SEL selector = @selector(localizedNameForPanelID:);
    if (![identity respondsToSelector:selector]) {
        return nil;
    }
    id name = ((id (*)(id, SEL, long long))objc_msgSend)(identity, selector, panelID);
    return [name isKindOfClass:NSString.class] ? name : nil;
}

@end
