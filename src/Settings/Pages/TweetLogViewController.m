//
//  TweetLogViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/TweetLogViewController.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "Core/BHTBundle.h"
#import "Core/BHTManager.h"
#import "Core/BHTTweetLog.h"
#import "ThemeColor/Palette.h"

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

#pragma mark - Theme

static id CurrentColorPalette(void) {
    Class settingsClass = objc_getClass("TAEColorSettings");
    if (!settingsClass) {
        return nil;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)((id)settingsClass, @selector(sharedSettings));
    id current = ((id (*)(id, SEL))objc_msgSend)(settings, @selector(currentColorPalette));
    return ((id (*)(id, SEL))objc_msgSend)(current, @selector(colorPalette));
}

static UIColor* PaletteColor(SEL selector, UIColor* fallback) {
    id palette = CurrentColorPalette();
    if (![palette respondsToSelector:selector]) {
        return fallback;
    }
    id color = ((id (*)(id, SEL))objc_msgSend)(palette, selector);
    return [color isKindOfClass:UIColor.class] ? color : fallback;
}

static UIColor* PrimaryTextColor(void) {
    return PaletteColor(@selector(textColor), UIColor.labelColor);
}

static UIColor* SecondaryTextColor(void) {
    return PaletteColor(@selector(tabBarItemColor), UIColor.secondaryLabelColor);
}

static UIFont* GroupFont(SEL selector, UIFont* fallback) {
    id group = [BHTManager sharedFontGroup];
    if (![group respondsToSelector:selector]) {
        return fallback;
    }
    id font = ((id (*)(id, SEL))objc_msgSend)(group, selector);
    return [font isKindOfClass:UIFont.class] ? font : fallback;
}

#pragma mark - Images

// Avatars and media thumbnails, cached in memory for the session.
static NSCache<NSString*, UIImage*>* ImageCache(void) {
    static NSCache* cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 400;
    });
    return cache;
}

static const void* ImageURLKey = &ImageURLKey;

static void LoadImage(UIImageView* imageView, NSString* urlString) {
    objc_setAssociatedObject(imageView, ImageURLKey, urlString, OBJC_ASSOCIATION_COPY_NONATOMIC);
    imageView.image = nil;
    if (urlString.length == 0) {
        return;
    }

    UIImage* cached = [ImageCache() objectForKey:urlString];
    if (cached) {
        imageView.image = cached;
        return;
    }

    NSURL* url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }
    __weak UIImageView* weakImageView = imageView;
    [[NSURLSession.sharedSession dataTaskWithURL:url
                               completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   UIImage* image = data ? [UIImage imageWithData:data] : nil;
                                   if (!image) {
                                       return;
                                   }
                                   [ImageCache() setObject:image forKey:urlString];
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       UIImageView* target = weakImageView;
                                       // The cell may have moved on to another Tweet.
                                       if ([objc_getAssociatedObject(target, ImageURLKey) isEqualToString:urlString]) {
                                           target.image = image;
                                       }
                                   });
                               }] resume];
}

// Twitter's image host serves smaller renditions on request.
static NSString* ThumbnailURL(NSString* urlString) {
    if (![urlString containsString:@"pbs.twimg.com"] || [urlString containsString:@"?"]) {
        return urlString;
    }
    return [urlString stringByAppendingString:@"?name=small"];
}

static NSString* AvatarURL(NSString* urlString) {
    return [urlString stringByReplacingOccurrencesOfString:@"_normal." withString:@"_bigger."];
}

#pragma mark - Text

static NSString* CountString(NSNumber* count) {
    static NSNumberFormatter* formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return count.longLongValue > 0 ? [formatter stringFromNumber:count] : @"";
}

// "3m" / "9h" / "2d" like the timeline, then the date.
static NSString* PostedString(NSDate* date) {
    if (![date isKindOfClass:NSDate.class]) {
        return @"";
    }

    NSTimeInterval age = -date.timeIntervalSinceNow;
    if (age < 7 * 24 * 60 * 60) {
        static NSDateComponentsFormatter* relative;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            relative = [NSDateComponentsFormatter new];
            relative.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
            relative.maximumUnitCount = 1;
            relative.allowedUnits = NSCalendarUnitMinute | NSCalendarUnitHour | NSCalendarUnitDay;
        });
        return [relative stringFromTimeInterval:MAX(age, 60)] ?: @"";
    }

    static NSDateFormatter* absolute;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        absolute = [NSDateFormatter new];
        [absolute setLocalizedDateFormatFromTemplate:@"yMd"];
    });
    return [absolute stringFromDate:date];
}

static NSString* SeenString(NSDate* date) {
    if (![date isKindOfClass:NSDate.class]) {
        return @"";
    }

    static NSDateFormatter* today;
    static NSDateFormatter* earlier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        today = [NSDateFormatter new];
        [today setLocalizedDateFormatFromTemplate:@"Hm"];
        earlier = [NSDateFormatter new];
        [earlier setLocalizedDateFormatFromTemplate:@"MdHm"];
    });
    NSDateFormatter* formatter = [NSCalendar.currentCalendar isDateInToday:date] ? today : earlier;
    return [NSString stringWithFormat:L(@"TWEET_LOG_SEEN_FORMAT"), [formatter stringFromDate:date]];
}

#pragma mark - Cell

@interface TweetLogCell : UITableViewCell
@property (nonatomic, strong) UILabel* retweetLabel;
@property (nonatomic, strong) UIImageView* avatarView;
@property (nonatomic, strong) UILabel* nameLabel;
@property (nonatomic, strong) UILabel* metaLabel;
@property (nonatomic, strong) UILabel* bodyLabel;
@property (nonatomic, strong) UIStackView* mediaStack;
@property (nonatomic, strong) NSLayoutConstraint* mediaHeight;
@property (nonatomic, strong) NSArray<UIImageView*>* mediaViews;
@property (nonatomic, strong) NSArray<UIImageView*>* playBadges;
@property (nonatomic, strong) UILabel* countsLabel;
@property (nonatomic, strong) UILabel* seenLabel;
- (void)configureWithEntry:(NSDictionary*)entry;
@end

@implementation TweetLogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;

        self.retweetLabel = [self labelWithFont:GroupFont(@selector(subtext2Font), [UIFont systemFontOfSize:13])
                                          color:SecondaryTextColor()
                                          lines:1];

        self.avatarView = [UIImageView new];
        self.avatarView.translatesAutoresizingMaskIntoConstraints = NO;
        self.avatarView.contentMode = UIViewContentModeScaleAspectFill;
        self.avatarView.clipsToBounds = YES;
        self.avatarView.layer.cornerRadius = 20;
        self.avatarView.backgroundColor = UIColor.secondarySystemFillColor;
        [self.contentView addSubview:self.avatarView];

        self.nameLabel = [self labelWithFont:GroupFont(@selector(bodyBoldFont), [UIFont boldSystemFontOfSize:15])
                                       color:PrimaryTextColor()
                                       lines:1];
        [self.nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                                        forAxis:UILayoutConstraintAxisHorizontal];
        self.metaLabel = [self labelWithFont:GroupFont(@selector(bodyFont), [UIFont systemFontOfSize:15])
                                       color:SecondaryTextColor()
                                       lines:1];
        [self.metaLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                        forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView* header = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel, self.metaLabel]];
        header.spacing = 4;
        header.alignment = UIStackViewAlignmentFirstBaseline;

        self.bodyLabel = [self labelWithFont:GroupFont(@selector(bodyFont), [UIFont systemFontOfSize:15])
                                       color:PrimaryTextColor()
                                       lines:0];

        NSMutableArray* mediaViews = [NSMutableArray array];
        NSMutableArray* playBadges = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; i++) {
            UIImageView* media = [UIImageView new];
            media.contentMode = UIViewContentModeScaleAspectFill;
            media.clipsToBounds = YES;
            media.backgroundColor = UIColor.secondarySystemFillColor;

            UIImageView* play = [[UIImageView alloc]
                initWithImage:[UIImage systemImageNamed:@"play.circle.fill"]];
            play.translatesAutoresizingMaskIntoConstraints = NO;
            play.tintColor = UIColor.whiteColor;
            [media addSubview:play];
            [NSLayoutConstraint activateConstraints:@[
                [play.centerXAnchor constraintEqualToAnchor:media.centerXAnchor],
                [play.centerYAnchor constraintEqualToAnchor:media.centerYAnchor],
                [play.widthAnchor constraintEqualToConstant:36],
                [play.heightAnchor constraintEqualToConstant:36],
            ]];

            [mediaViews addObject:media];
            [playBadges addObject:play];
        }
        self.mediaViews = mediaViews;
        self.playBadges = playBadges;
        self.mediaStack = [[UIStackView alloc] initWithArrangedSubviews:mediaViews];
        self.mediaStack.distribution = UIStackViewDistributionFillEqually;
        self.mediaStack.spacing = 2;
        self.mediaStack.layer.cornerRadius = 12;
        self.mediaStack.clipsToBounds = YES;
        self.mediaHeight = [self.mediaStack.heightAnchor constraintEqualToConstant:0];
        self.mediaHeight.active = YES;

        self.countsLabel = [self labelWithFont:GroupFont(@selector(subtext2Font), [UIFont systemFontOfSize:13])
                                         color:SecondaryTextColor()
                                         lines:1];
        self.seenLabel = [self labelWithFont:GroupFont(@selector(subtext2Font), [UIFont systemFontOfSize:13])
                                       color:SecondaryTextColor()
                                       lines:1];

        UIStackView* column = [[UIStackView alloc] initWithArrangedSubviews:@[
            self.retweetLabel, header, self.bodyLabel, self.mediaStack, self.countsLabel, self.seenLabel
        ]];
        column.axis = UILayoutConstraintAxisVertical;
        column.spacing = 4;
        [column setCustomSpacing:8 afterView:self.bodyLabel];
        [column setCustomSpacing:8 afterView:self.mediaStack];
        column.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:column];

        NSLayoutConstraint* avatarBottom =
            [self.avatarView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor
                                                                   constant:-12];
        [NSLayoutConstraint activateConstraints:@[
            [self.avatarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.avatarView.topAnchor constraintEqualToAnchor:header.topAnchor],
            [self.avatarView.widthAnchor constraintEqualToConstant:40],
            [self.avatarView.heightAnchor constraintEqualToConstant:40],
            avatarBottom,
            [column.leadingAnchor constraintEqualToAnchor:self.avatarView.trailingAnchor constant:10],
            [column.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [column.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [column.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        ]];
    }
    return self;
}

- (UILabel*)labelWithFont:(UIFont*)font color:(UIColor*)color lines:(NSInteger)lines {
    UILabel* label = [UILabel new];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    return label;
}

- (NSAttributedString*)countsTextForEntry:(NSDictionary*)entry {
    NSMutableAttributedString* text = [NSMutableAttributedString new];
    NSDictionary* attributes = @{NSForegroundColorAttributeName: SecondaryTextColor(),
                                 NSFontAttributeName: self.countsLabel.font};
    NSArray<NSArray*>* parts = @[
        @[@"bubble.left", entry[@"replies"] ?: @0],
        @[@"arrow.2.squarepath", entry[@"retweets"] ?: @0],
        @[@"heart", entry[@"likes"] ?: @0],
    ];
    for (NSArray* part in parts) {
        NSTextAttachment* icon = [NSTextAttachment new];
        icon.image = [[UIImage systemImageNamed:part[0]] imageWithTintColor:SecondaryTextColor()
                                                              renderingMode:UIImageRenderingModeAlwaysOriginal];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:icon]];
        NSString* count = [part[1] isKindOfClass:NSNumber.class] ? CountString(part[1]) : @"";
        [text appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:[NSString stringWithFormat:@" %@        ", count]
                                             attributes:attributes]];
    }
    return text;
}

- (void)configureWithEntry:(NSDictionary*)entry {
    NSString* retweetedBy = entry[@"rtBy"];
    self.retweetLabel.hidden = retweetedBy.length == 0;
    self.retweetLabel.text = retweetedBy.length
                                 ? [NSString stringWithFormat:L(@"TWEET_LOG_RETWEETED_BY"), retweetedBy]
                                 : nil;

    LoadImage(self.avatarView, AvatarURL(entry[@"avatar"]));
    self.nameLabel.text = [entry[@"name"] length] ? entry[@"name"] : entry[@"handle"];
    NSString* handle = [entry[@"handle"] length] ? [@"@" stringByAppendingString:entry[@"handle"]] : @"";
    NSString* posted = PostedString(entry[@"date"]);
    self.metaLabel.text = posted.length ? [NSString stringWithFormat:@"%@ · %@", handle, posted] : handle;

    NSString* body = entry[@"text"];
    self.bodyLabel.text = body;
    self.bodyLabel.hidden = body.length == 0;

    NSArray* media = [entry[@"media"] isKindOfClass:NSArray.class] ? entry[@"media"] : @[];
    for (NSUInteger i = 0; i < self.mediaViews.count; i++) {
        UIImageView* view = self.mediaViews[i];
        NSDictionary* item = i < media.count ? media[i] : nil;
        view.hidden = item == nil;
        self.playBadges[i].hidden = ![item[@"video"] boolValue];
        LoadImage(view, item ? ThumbnailURL(item[@"url"]) : nil);
    }
    self.mediaStack.hidden = media.count == 0;
    self.mediaHeight.constant = media.count == 0 ? 0 : (media.count == 1 ? 200 : 140);

    self.countsLabel.attributedText = [self countsTextForEntry:entry];
    self.seenLabel.text = SeenString(entry[@"seen"]);
}

@end

#pragma mark - View controller

@interface TweetLogViewController ()
@property (nonatomic, strong) UITableView* tableView;
@property (nonatomic, strong) UILabel* summaryLabel;
@property (nonatomic, strong) UILabel* emptyLabel;
@property (nonatomic, copy) NSArray<NSDictionary*>* entries;
@property (nonatomic) BOOL needsReload;
@end

@implementation TweetLogViewController

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [Palette currentBackgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [Palette currentBackgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 160;
    self.tableView.separatorInset = UIEdgeInsetsZero;
    [self.tableView registerClass:[TweetLogCell class] forCellReuseIdentifier:@"TweetLogCell"];
    self.tableView.tableHeaderView = [self makeHeaderView];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = L(@"TWEET_LOG_EMPTY");
    self.emptyLabel.textColor = SecondaryTextColor();
    self.emptyLabel.font = GroupFont(@selector(bodyFont), [UIFont systemFontOfSize:15]);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(logDidChange)
                                               name:BHTTweetLogDidChangeNotification
                                             object:nil];
    [self reloadEntries];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.needsReload) {
        [self reloadEntries];
    }
}

// History's tab container asks pages for their scroll view.
- (UIScrollView*)tfn_contentScrollView {
    return self.tableView;
}

- (UIView*)makeHeaderView {
    UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.summaryLabel = [UILabel new];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.font = GroupFont(@selector(subtext2Font), [UIFont systemFontOfSize:13]);
    self.summaryLabel.textColor = SecondaryTextColor();
    [header addSubview:self.summaryLabel];

    UIButton* clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [clear setTitle:L(@"TWEET_LOG_CLEAR") forState:UIControlStateNormal];
    [clear setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    clear.titleLabel.font = GroupFont(@selector(subtext2Font), [UIFont systemFontOfSize:13]);
    [clear addTarget:self action:@selector(confirmClear) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:clear];

    [NSLayoutConstraint activateConstraints:@[
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.summaryLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [clear.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [clear.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [clear.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.summaryLabel.trailingAnchor constant:12],
    ]];
    return header;
}

- (void)logDidChange {
    // Recording goes on while the timeline scrolls; catch up once visible.
    if (self.viewIfLoaded.window) {
        [self reloadEntries];
    } else {
        self.needsReload = YES;
    }
}

- (void)reloadEntries {
    self.needsReload = NO;
    self.entries = [BHTTweetLog entries];
    self.summaryLabel.text = [NSString stringWithFormat:L(@"TWEET_LOG_COUNT_FORMAT"),
                                                        (long)self.entries.count, (long)BHTTweetLog.limit];
    self.tableView.backgroundView = self.entries.count == 0 ? self.emptyLabel : nil;
    [self.tableView reloadData];
}

- (void)confirmClear {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:L(@"TWEET_LOG_CLEAR_CONFIRM_TITLE")
                                            message:L(@"TWEET_LOG_CLEAR_CONFIRM_MESSAGE")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"TWEET_LOG_CLEAR")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                [BHTTweetLog clear];
                                                [self reloadEntries];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Opening Tweets

// X's own URL handling opens the Tweet in the app, the same way NeoFreeBird
// does after posting a reply on the web (WebReply.x).
- (void)openEntry:(NSDictionary*)entry {
    NSString* statusID = entry[@"id"];
    NSURL* url = statusID.length
                     ? [NSURL URLWithString:[NSString stringWithFormat:@"twitter://status?id=%@", statusID]]
                     : nil;
    id delegate = UIApplication.sharedApplication.delegate;
    if (url && [delegate respondsToSelector:@selector(openURL:options:)]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(openURL:options:), url, @{});
    }
}

- (NSString*)linkForEntry:(NSDictionary*)entry {
    NSString* domain = [NSUserDefaults.standardUserDefaults stringForKey:@"sharing_domain"];
    if (domain.length == 0) {
        domain = @"x.com";
    }
    NSString* handle = [entry[@"handle"] length] ? entry[@"handle"] : @"i";
    return [NSString stringWithFormat:@"https://%@/%@/status/%@", domain, handle, entry[@"id"]];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    TweetLogCell* cell = [tableView dequeueReusableCellWithIdentifier:@"TweetLogCell" forIndexPath:indexPath];
    [cell configureWithEntry:self.entries[indexPath.row]];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openEntry:self.entries[indexPath.row]];
}

- (UIContextMenuConfiguration*)tableView:(UITableView*)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
                                        point:(CGPoint)point {
    NSDictionary* entry = self.entries[indexPath.row];
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu*(NSArray<UIMenuElement*>* suggested) {
                         UIAction* open = [UIAction actionWithTitle:L(@"TWEET_LOG_OPEN")
                                                              image:[UIImage systemImageNamed:@"arrow.up.right.square"]
                                                         identifier:nil
                                                            handler:^(UIAction* action) {
                                                                [self openEntry:entry];
                                                            }];
                         UIAction* copy = [UIAction actionWithTitle:L(@"TWEET_LOG_COPY_LINK")
                                                              image:[UIImage systemImageNamed:@"link"]
                                                         identifier:nil
                                                            handler:^(UIAction* action) {
                                                                UIPasteboard.generalPasteboard.string =
                                                                    [self linkForEntry:entry];
                                                            }];
                         UIAction* remove = [UIAction actionWithTitle:L(@"TWEET_LOG_REMOVE")
                                                                image:[UIImage systemImageNamed:@"trash"]
                                                           identifier:nil
                                                              handler:^(UIAction* action) {
                                                                  [BHTTweetLog removeEntryWithID:entry[@"id"]];
                                                                  [self reloadEntries];
                                                              }];
                         remove.attributes = UIMenuElementAttributesDestructive;
                         return [UIMenu menuWithTitle:@"" children:@[open, copy, remove]];
                     }];
}

@end
