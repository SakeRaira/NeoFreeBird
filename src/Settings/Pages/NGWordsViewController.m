//
//  NGWordsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/NGWordsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTNGWords.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"
#import "ThemeColor/Palette.h"

typedef NS_ENUM(NSInteger, NGSection) {
    NGSectionSettings,
    NGSectionWords,
    NGSectionCount,
};

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

@interface NGWordsViewController ()
@property (nonatomic, strong) TFNTwitterAccount* account;
@property (nonatomic, strong) UITableView* tableView;
@property (nonatomic, copy) NSArray<NSString*>* words;
@end

@implementation NGWordsViewController

- (instancetype)initWithAccount:(TFNTwitterAccount*)account {
    if ((self = [super init])) {
        _account = account;
        _words = BHTNGWords.words;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSString* title = L(@"NG_WORDS_TITLE");
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
    [self.tableView registerClass:[ModernSettingsToggleCell class] forCellReuseIdentifier:@"InfoCell"];
    [self.tableView registerClass:[ModernSettingsCompactButtonCell class]
           forCellReuseIdentifier:@"CompactButtonCell"];
    [self.view addSubview:self.tableView];
}

- (void)saveWords:(NSArray<NSString*>*)words {
    [BHTNGWords setWords:words];
    self.words = BHTNGWords.words;
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return NGSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return section == NGSectionSettings ? 1 : self.words.count + 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == NGSectionWords ? L(@"NG_WORDS_LIST_HEADER") : nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return section == NGSectionWords ? L(@"NG_WORDS_LIST_FOOTER") : nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (indexPath.section == NGSectionSettings) {
        ModernSettingsToggleCell* cell = [tableView dequeueReusableCellWithIdentifier:@"ToggleCell"
                                                                         forIndexPath:indexPath];
        [cell configureWithTitle:L(@"NG_WORDS_ENABLED_TITLE") subtitle:L(@"NG_WORDS_ENABLED_DETAIL")];
        cell.toggleSwitch.on = BHTNGWords.enabled;
        [cell.toggleSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
        [cell addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    if (indexPath.row < (NSInteger)self.words.count) {
        NSString* word = self.words[indexPath.row];
        ModernSettingsToggleCell* cell = [tableView dequeueReusableCellWithIdentifier:@"InfoCell"
                                                                         forIndexPath:indexPath];
        [cell configureWithTitle:word
                        subtitle:[BHTNGWords isRegexWord:word] ? L(@"NG_WORDS_REGEX_LABEL") : @""];
        cell.toggleSwitch.hidden = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    ModernSettingsCompactButtonCell* cell = [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                                                            forIndexPath:indexPath];
    [cell configureWithTitle:L(@"NG_WORDS_ADD") subtitle:@""];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != NGSectionWords) {
        return;
    }

    if (indexPath.row < (NSInteger)self.words.count) {
        [self showActionsForWordAtIndex:indexPath.row];
    } else {
        [self promptWordReplacingIndex:NSNotFound];
    }
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (indexPath.section != NGSectionWords || indexPath.row >= (NSInteger)self.words.count) {
        return nil;
    }

    NSInteger index = indexPath.row;
    UIContextualAction* delete =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:L(@"NG_WORDS_DELETE")
                                              handler:^(UIContextualAction* action, UIView* sourceView,
                                                        void (^completion)(BOOL)) {
                                                  [self deleteWordAtIndex:index];
                                                  completion(YES);
                                              }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark - Actions

- (void)enabledChanged:(UISwitch*)sender {
    [BHTNGWords setEnabled:sender.isOn];
}

- (void)deleteWordAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.words.count) {
        return;
    }
    NSMutableArray* words = [self.words mutableCopy];
    [words removeObjectAtIndex:index];
    [self saveWords:words];
}

- (void)showMessage:(NSString*)message {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:message
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"OK_ACTION_LABEL")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showActionsForWordAtIndex:(NSInteger)index {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:self.words[index]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"NG_WORDS_EDIT")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                [self promptWordReplacingIndex:index];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"NG_WORDS_DELETE")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                [self deleteWordAtIndex:index];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Adds a word, or replaces the one at `index` when it isn't NSNotFound.
- (void)promptWordReplacingIndex:(NSInteger)index {
    BOOL editing = index != NSNotFound && index < (NSInteger)self.words.count;
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:L(editing ? @"NG_WORDS_EDIT" : @"NG_WORDS_ADD")
                                            message:L(@"NG_WORDS_ADD_MESSAGE")
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController* weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = L(@"NG_WORDS_PLACEHOLDER");
        field.text = editing ? self.words[index] : nil;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:L(@"SAVE_ACTION_LABEL")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* word = [weakAlert.textFields.firstObject.text
                                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                     if (word.length == 0) {
                                         return;
                                     }

                                     switch ([BHTNGWords validityOfWord:word]) {
                                         case BHTNGWordEmpty:
                                             [self showMessage:L(@"NG_WORDS_EMPTY_AFTER_NORMALIZE")];
                                             return;
                                         case BHTNGWordInvalidRegex:
                                             [self showMessage:L(@"NG_WORDS_INVALID_REGEX")];
                                             return;
                                         case BHTNGWordValid:
                                             break;
                                     }

                                     NSMutableArray* words = [self.words mutableCopy];
                                     NSUInteger existing = [words indexOfObject:word];
                                     if (existing != NSNotFound && (!editing || existing != (NSUInteger)index)) {
                                         [self showMessage:L(@"NG_WORDS_DUPLICATE")];
                                         return;
                                     }

                                     if (editing && index < (NSInteger)words.count) {
                                         words[index] = word;
                                     } else {
                                         [words addObject:word];
                                     }
                                     [self saveWords:words];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
