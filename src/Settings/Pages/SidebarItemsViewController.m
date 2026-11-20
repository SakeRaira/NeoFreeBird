//
//  SidebarItemsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/SidebarItemsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSidebarItems.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"
#import "ThemeColor/Palette.h"

// Defined in FeatureSwitches.x: has the open drawers take a new snapshot.
extern void applySidebarItemsSetting(void);

typedef NS_ENUM(NSInteger, SidebarSection) {
    SidebarSectionItems,
    SidebarSectionReset,
    SidebarSectionCount,
};

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

@interface SidebarItemsViewController ()
@property (nonatomic, strong) TFNTwitterAccount* account;
@property (nonatomic, strong) UITableView* tableView;
@property (nonatomic, copy) NSArray<NSNumber*>* panelIDs;
@end

@implementation SidebarItemsViewController

- (instancetype)initWithAccount:(TFNTwitterAccount*)account {
    if ((self = [super init])) {
        _account = account;
        _panelIDs = BHTSidebarItems.candidatePanelIDs;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSString* title = L(@"SIDEBAR_ITEMS_TITLE");
    if (self.account) {
        self.navigationItem.titleView =
            [objc_getClass("TFNTitleView") titleViewWithTitle:title
                                                     subtitle:self.account.displayUsername];
    } else {
        self.title = title;
    }

    self.view.backgroundColor = [Palette currentBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [Palette currentBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self.tableView registerClass:[ModernSettingsToggleCell class] forCellReuseIdentifier:@"ToggleCell"];
    [self.tableView registerClass:[ModernSettingsCompactButtonCell class]
           forCellReuseIdentifier:@"CompactButtonCell"];
    [self.view addSubview:self.tableView];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return SidebarSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return section == SidebarSectionItems ? self.panelIDs.count : 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == SidebarSectionItems ? L(@"SIDEBAR_ITEMS_HEADER") : nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return section == SidebarSectionItems ? L(@"SIDEBAR_ITEMS_FOOTER") : nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (indexPath.section == SidebarSectionReset) {
        ModernSettingsCompactButtonCell* cell = [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                                                                forIndexPath:indexPath];
        [cell configureWithTitle:L(@"SIDEBAR_ITEMS_SHOW_ALL") subtitle:@""];
        return cell;
    }

    long long panelID = self.panelIDs[indexPath.row].longLongValue;
    BOOL onTabBar = [BHTSidebarItems.tabBarPanelIDs containsObject:@(panelID)];

    ModernSettingsToggleCell* cell = [tableView dequeueReusableCellWithIdentifier:@"ToggleCell"
                                                                     forIndexPath:indexPath];
    [cell configureWithTitle:[BHTSidebarItems nameForPanelID:panelID] ?: @""
                    subtitle:onTabBar ? L(@"SIDEBAR_ITEMS_ON_TAB_BAR") : @""];
    cell.toggleSwitch.on = ![BHTSidebarItems isPanelHidden:panelID];
    cell.toggleSwitch.tag = indexPath.row;
    [cell.toggleSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    [cell addTarget:self action:@selector(itemToggled:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != SidebarSectionReset) {
        return;
    }
    [BHTSidebarItems showAllPanels];
    applySidebarItemsSetting();
    [tableView reloadData];
}

#pragma mark - Actions

- (void)itemToggled:(UISwitch*)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.panelIDs.count) {
        return;
    }
    [BHTSidebarItems setPanel:self.panelIDs[sender.tag].longLongValue hidden:!sender.isOn];
    applySidebarItemsSetting();
}

@end
