#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ==================== Constants ====================
static NSString * const kHistoryFileName = @"com.mody.copymody.history.json";
static NSInteger const kMaxHistoryItems = 50;
static NSInteger const kButtonTag = 88442211;

// ==================== Helpers ====================
static NSArray<UIWindow *> *CMAllWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [result addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return result;
}

static UIWindow *CMKeyWindow(void) {
    for (UIWindow *w in CMAllWindows()) {
        if (w.isKeyWindow) return w;
    }
    return CMAllWindows().firstObject;
}

/// Returns a writable path that works under RootHide / normal jailbreaks
static NSString *CMHistoryPath(void) {
    // 1) Preferred: mobile Preferences
    NSString *pref = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kHistoryFileName];
    // 2) Fallback: Library/CopyMody
    NSString *lib  = [NSString stringWithFormat:@"/var/mobile/Library/CopyMody/%@", kHistoryFileName];
    // 3) Last resort: tmp (still better than nothing for testing)
    NSString *tmp  = [NSTemporaryDirectory() stringByAppendingPathComponent:kHistoryFileName];

    NSFileManager *fm = [NSFileManager defaultManager];

    // Ensure dirs exist
    [fm createDirectoryAtPath:[pref stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[lib  stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    // Prefer existing file location
    if ([fm fileExistsAtPath:pref]) return pref;
    if ([fm fileExistsAtPath:lib])  return lib;

    // Try write test on pref
    if ([@"[]" writeToFile:pref atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        return pref;
    }
    if ([@"[]" writeToFile:lib atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        return lib;
    }
    return tmp;
}

// ==================== History Manager ====================
@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)clearAll;
- (void)captureCurrentPasteboard;
@end

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
    NSString *_path;
}

+ (instancetype)shared {
    static CMHistoryManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CMHistoryManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _path = CMHistoryPath();
        _items = [NSMutableArray array];
        [self load];
        NSLog(@"[CopyMody] History path: %@", _path);
    }
    return self;
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSArray class]]) {
        _items = [obj mutableCopy];
    }
}

- (void)save {
    if (!_path) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:_items options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        BOOL ok = [data writeToFile:_path atomically:YES];
        NSLog(@"[CopyMody] save %@ → %@", ok ? @"OK" : @"FAIL", _path);
    }
}

- (NSArray<NSDictionary *> *)allItems {
    [self load]; // always reload from disk
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (!text) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    // Limit extremely long pastes
    if (trimmed.length > 10000) {
        trimmed = [trimmed substringToIndex:10000];
    }

    [self load];

    if (_items.count > 0) {
        NSString *last = _items.firstObject[@"text"];
        if ([last isEqualToString:trimmed]) return;
    }

    NSDictionary *entry = @{
        @"text"      : trimmed,
        @"timestamp" : @((NSInteger)[[NSDate date] timeIntervalSince1970])
    };
    [_items insertObject:entry atIndex:0];

    while ((NSInteger)_items.count > kMaxHistoryItems) {
        [_items removeLastObject];
    }
    [self save];
    NSLog(@"[CopyMody] added: %@... (total %lu)", [trimmed substringToIndex:MIN(30, trimmed.length)], (unsigned long)_items.count);
}

- (void)removeItemAtIndex:(NSInteger)index {
    [self load];
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items removeObjectAtIndex:index];
    [self save];
}

- (void)clearAll {
    [_items removeAllObjects];
    [self save];
}

- (void)captureCurrentPasteboard {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    // Prefer string
    NSString *str = pb.string;
    if (str.length > 0) {
        [self addText:str];
        return;
    }
    // Fallback: first string-like item
    if (pb.numberOfItems > 0) {
        NSArray *items = pb.items;
        for (NSDictionary *item in items) {
            for (id key in item) {
                id val = item[key];
                if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                    [self addText:val];
                    return;
                }
                if ([val isKindOfClass:[NSData class]]) {
                    NSString *decoded = [[NSString alloc] initWithData:val encoding:NSUTF8StringEncoding];
                    if (decoded.length > 0) {
                        [self addText:decoded];
                        return;
                    }
                }
            }
        }
    }
}

@end

// ==================== History UI ====================
@interface CMHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation CMHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // CRITICAL: capture whatever is currently in the pasteboard right when UI opens
    [[CMHistoryManager shared] captureCurrentPasteboard];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"CopyMody";
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"مسح الكل" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [clearBtn addTarget:self action:@selector(clearAllTapped) forControlEvents:UIControlEventTouchUpInside];
    clearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:clearBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"إغلاق" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:closeBtn];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.heightAnchor constraintEqualToConstant:420],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],

        [clearBtn.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-12],

        [closeBtn.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.tableView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12],
        [self.tableView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]
    ]];

    self.items = [[CMHistoryManager shared] allItems];
    [self.tableView reloadData];

    // Empty state label
    if (self.items.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"لا يوجد عناصر بعد\nانسخ نصاً ثم افتح القائمة";
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 2;
        empty.textColor = [UIColor secondaryLabelColor];
        empty.font = [UIFont systemFontOfSize:15];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:empty];
        [NSLayoutConstraint activateConstraints:@[
            [empty.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
            [empty.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor]
        ]];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];

    NSDictionary *item = self.items[indexPath.row];
    NSString *text = item[@"text"] ?: @"";

    cell.textLabel.numberOfLines = 3;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.text = text;

    NSTimeInterval ts = [item[@"timestamp"] doubleValue];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = [fmt stringFromDate:date];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.items[indexPath.row];
    NSString *text = item[@"text"];
    if (!text) return;

    [[UIPasteboard generalPasteboard] setString:text];

    UIWindow *keyWindow = CMKeyWindow();
    UIView *firstResponder = [self findFirstResponder:keyWindow];

    if ([firstResponder respondsToSelector:@selector(paste:)]) {
        [firstResponder paste:nil];
    } else if ([firstResponder isKindOfClass:[UITextField class]]) {
        [(UITextField *)firstResponder insertText:text];
    } else if ([firstResponder isKindOfClass:[UITextView class]]) {
        [(UITextView *)firstResponder insertText:text];
    }

    [self closeTapped];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {

    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"حذف"
                          handler:^(__unused UIContextualAction *action,
                                    __unused UIView *sourceView,
                                    void (^completionHandler)(BOOL)) {

        [[CMHistoryManager shared] removeItemAtIndex:indexPath.row];
        self.items = [[CMHistoryManager shared] allItems];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (void)clearAllTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"مسح السجل"
                         message:@"هل تريد حذف جميع العناصر؟"
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [[CMHistoryManager shared] clearAll];
        self.items = @[];
        [self.tableView reloadData];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onDismiss) self.onDismiss();
    }];
}

- (UIView *)findFirstResponder:(UIView *)view {
    if (!view) return nil;
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = [self findFirstResponder:sub];
        if (found) return found;
    }
    return nil;
}

@end

// ==================== Floating Button ====================
static UIWindow *cmOverlayWindow = nil;
static UIButton *cmFloatButton = nil;

static void CMRemoveAllButtons(void) {
    for (UIWindow *w in CMAllWindows()) {
        for (UIView *v in [w.subviews copy]) {
            if (v.tag == kButtonTag) [v removeFromSuperview];
        }
    }
    cmFloatButton = nil;
}

static void CMPresentHistory(void) {
    if (cmOverlayWindow) return;

    // Capture pasteboard BEFORE showing UI
    [[CMHistoryManager shared] captureCurrentPasteboard];

    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (s.activationState == UISceneActivationStateForegroundActive &&
            [s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return;

    cmOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    cmOverlayWindow.windowLevel = UIWindowLevelAlert + 100;
    cmOverlayWindow.backgroundColor = [UIColor clearColor];

    CMHistoryViewController *vc = [[CMHistoryViewController alloc] init];
    vc.onDismiss = ^{
        cmOverlayWindow.hidden = YES;
        cmOverlayWindow = nil;
    };

    cmOverlayWindow.rootViewController = vc;
    cmOverlayWindow.hidden = NO;
}

static void CMShowFloatButton(CGRect keyboardFrame) {
    UIWindow *keyWindow = CMKeyWindow();
    if (!keyWindow) return;

    CMRemoveAllButtons();

    CGFloat btnSize = 36.0;
    CGFloat pad = 6.0;

    CGFloat x = keyboardFrame.origin.x + keyboardFrame.size.width - btnSize - pad - 4;
    CGFloat y = keyboardFrame.origin.y + keyboardFrame.size.height - btnSize - pad - 4;

    if (keyboardFrame.size.height < 50) {
        x = keyWindow.bounds.size.width - btnSize - 12;
        y = keyWindow.bounds.size.height - 90;
    }

    cmFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    cmFloatButton.tag = kButtonTag;
    cmFloatButton.frame = CGRectMake(x, y, btnSize, btnSize);
    cmFloatButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:0.92 alpha:0.92];
    cmFloatButton.layer.cornerRadius = btnSize / 2.0;
    cmFloatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    cmFloatButton.layer.shadowOpacity = 0.25;
    cmFloatButton.layer.shadowOffset = CGSizeMake(0, 1);
    cmFloatButton.layer.shadowRadius = 3;

    [cmFloatButton setTitle:@"📋" forState:UIControlStateNormal];
    cmFloatButton.titleLabel.font = [UIFont systemFontOfSize:17];

    [cmFloatButton addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        CMPresentHistory();
    }] forControlEvents:UIControlEventTouchUpInside];

    cmFloatButton.layer.zPosition = 9999;
    [keyWindow addSubview:cmFloatButton];
}

static void CMHideFloatButton(void) {
    CMRemoveAllButtons();
}

// ==================== Hooks ====================

%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    if (string.length > 0) {
        [[CMHistoryManager shared] addText:string];
    }
}

- (void)setItems:(NSArray *)items {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[CMHistoryManager shared] captureCurrentPasteboard];
    });
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    if (strings.count > 0 && [strings.firstObject length] > 0) {
        [[CMHistoryManager shared] addText:strings.firstObject];
    }
}

%end

%ctor {
    // Pasteboard change notification
    [[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [[CMHistoryManager shared] captureCurrentPasteboard];
    }];

    // Keyboard
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        UIWindow *keyWindow = CMKeyWindow();
        if (keyWindow) {
            kbFrame = [keyWindow convertRect:kbFrame fromWindow:nil];
        }
        CMShowFloatButton(kbFrame);
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        CMHideFloatButton();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        CMHideFloatButton();
    }];

    NSLog(@"[CopyMody] v0.1.3 loaded");
}
