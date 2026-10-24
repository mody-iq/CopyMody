#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kHistoryFileName = @"com.mody.copymody.history.json";
static NSInteger const kMaxHistoryItems = 50;
static NSInteger const kButtonTag = 88442211;

static NSInteger cmLastChangeCount = -1;
static BOOL cmIsCapturing = NO;
static NSTimeInterval cmLastCaptureTime = 0;

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

static NSString *CMHistoryPath(void) {
    NSString *pref = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kHistoryFileName];
    NSString *lib  = [NSString stringWithFormat:@"/var/mobile/Library/CopyMody/%@", kHistoryFileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[pref stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[lib  stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm fileExistsAtPath:pref]) return pref;
    if ([fm fileExistsAtPath:lib])  return lib;
    // try create pref
    if ([@"[]" writeToFile:pref atomically:YES encoding:NSUTF8StringEncoding error:nil]) return pref;
    if ([@"[]" writeToFile:lib  atomically:YES encoding:NSUTF8StringEncoding error:nil]) return lib;
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kHistoryFileName];
}

// ==================== History Manager ====================
@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)clearAll;
- (void)tryCaptureFromHook:(NSString *)string; // only from our hooks, safe
@end

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
    NSString *_path;
    dispatch_queue_t _ioQueue;
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
        _ioQueue = dispatch_queue_create("com.mody.copymody.io", DISPATCH_QUEUE_SERIAL);
        [self loadSync];
        NSLog(@"[CopyMody] path=%@", _path);
    }
    return self;
}

- (void)loadSync {
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSArray class]]) {
        _items = [obj mutableCopy];
    }
}

- (void)saveAsync {
    NSArray *snapshot = [_items copy];
    NSString *path = _path;
    dispatch_async(_ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data) [data writeToFile:path atomically:YES];
    });
}

- (NSArray<NSDictionary *> *)allItems {
    // Return in-memory copy only – never block UI with disk/pasteboard
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (!text) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    if (trimmed.length > 8000) trimmed = [trimmed substringToIndex:8000];

    // duplicate check
    if (_items.count > 0) {
        NSString *last = _items.firstObject[@"text"];
        if ([last isEqualToString:trimmed]) return;
    }

    NSDictionary *entry = @{
        @"text" : trimmed,
        @"timestamp" : @((NSInteger)[[NSDate date] timeIntervalSince1970])
    };
    [_items insertObject:entry atIndex:0];
    while ((NSInteger)_items.count > kMaxHistoryItems) {
        [_items removeLastObject];
    }
    [self saveAsync];
}

- (void)tryCaptureFromHook:(NSString *)string {
    // Called only from our setString/setItems hooks – string already known, no pasteboard read
    if (cmIsCapturing) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - cmLastCaptureTime < 0.35) return; // debounce
    cmLastCaptureTime = now;
    cmIsCapturing = YES;
    [self addText:string];
    cmIsCapturing = NO;
}

- (void)removeItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items removeObjectAtIndex:index];
    [self saveAsync];
}

- (void)clearAll {
    [_items removeAllObjects];
    [self saveAsync];
}

@end

// ==================== History UI ====================
@interface CMHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation CMHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];

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
    self.tableView.estimatedRowHeight = 56;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"لا يوجد عناصر\nانسخ نصاً داخل هذا التطبيق";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 2;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.hidden = YES;
    [card addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.heightAnchor constraintEqualToConstant:400],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],

        [clearBtn.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-12],

        [closeBtn.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.tableView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [self.tableView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor]
    ]];

    [self reloadData];
}

- (void)reloadData {
    self.items = [[CMHistoryManager shared] allItems];
    self.emptyLabel.hidden = (self.items.count > 0);
    [self.tableView reloadData];
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
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *text = self.items[indexPath.row][@"text"];
    if (!text) return;

    // Set pasteboard (may trigger our hook – guarded by debounce)
    [[UIPasteboard generalPasteboard] setString:text];

    UIWindow *keyWindow = CMKeyWindow();
    UIView *fr = [self findFirstResponder:keyWindow];
    if ([fr isKindOfClass:[UITextField class]]) {
        [(UITextField *)fr insertText:text];
    } else if ([fr isKindOfClass:[UITextView class]]) {
        [(UITextView *)fr insertText:text];
    } else if ([fr respondsToSelector:@selector(paste:)]) {
        [fr paste:nil];
    }
    [self closeTapped];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"حذف"
        handler:^(__unused UIContextualAction *a, __unused UIView *v, void (^done)(BOOL)) {
            [[CMHistoryManager shared] removeItemAtIndex:indexPath.row];
            [self reloadData];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)clearAllTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"مسح السجل"
                                                                   message:@"حذف جميع العناصر؟"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [[CMHistoryManager shared] clearAll];
        [self reloadData];
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
        UIView *f = [self findFirstResponder:sub];
        if (f) return f;
    }
    return nil;
}

@end

// ==================== Button + Present ====================
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
    cmOverlayWindow.windowLevel = UIWindowLevelAlert + 50;
    cmOverlayWindow.backgroundColor = [UIColor clearColor];
    cmOverlayWindow.userInteractionEnabled = YES;

    CMHistoryViewController *vc = [[CMHistoryViewController alloc] init];
    vc.onDismiss = ^{
        cmOverlayWindow.hidden = YES;
        cmOverlayWindow.rootViewController = nil;
        cmOverlayWindow = nil;
    };

    cmOverlayWindow.rootViewController = vc;
    [cmOverlayWindow makeKeyAndVisible];
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
    [cmFloatButton addAction:[UIAction actionWithHandler:^(__unused UIAction *a) {
        CMPresentHistory();
    }] forControlEvents:UIControlEventTouchUpInside];
    cmFloatButton.layer.zPosition = 9999;
    [keyWindow addSubview:cmFloatButton];
}

static void CMHideFloatButton(void) {
    CMRemoveAllButtons();
}

// ==================== Hooks (NO pasteboard .string reads) ====================

%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    if (string.length > 0 && !cmIsCapturing) {
        [[CMHistoryManager shared] tryCaptureFromHook:string];
    }
}

- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    if (strings.count > 0 && [strings.firstObject length] > 0 && !cmIsCapturing) {
        [[CMHistoryManager shared] tryCaptureFromHook:strings.firstObject];
    }
}

- (void)setItems:(NSArray *)items {
    %orig;
    if (cmIsCapturing || items.count == 0) return;
    // Extract string without calling pb.string (avoids privacy prompt / freeze)
    for (NSDictionary *item in items) {
        id val = item[@"public.utf8-plain-text"] ?: item[@"public.plain-text"] ?: item[@"public.text"];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            [[CMHistoryManager shared] tryCaptureFromHook:val];
            return;
        }
        if ([val isKindOfClass:[NSData class]]) {
            NSString *s = [[NSString alloc] initWithData:val encoding:NSUTF8StringEncoding];
            if (s.length > 0) {
                [[CMHistoryManager shared] tryCaptureFromHook:s];
                return;
            }
        }
    }
}

%end

%ctor {
    // Keyboard only – no UIPasteboardChangedNotification (can cause freezes on iOS 18)
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        UIWindow *kw = CMKeyWindow();
        if (kw) kb = [kw convertRect:kb fromWindow:nil];
        CMShowFloatButton(kb);
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        CMHideFloatButton();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        CMHideFloatButton();
    }];

    NSLog(@"[CopyMody] v0.1.4 loaded (no blocking pasteboard reads)");
}
