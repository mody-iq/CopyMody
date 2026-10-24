#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <roothide.h>

static NSString * const kSuiteName = @"com.mody.copymody.history";
static NSString * const kStoreKey = @"store2";
static NSInteger const kMaxHistoryItems = 50;
static NSInteger const kButtonTag = 88442211;

static NSInteger cmLastCaptured = -1;
static NSInteger cmOwnChangeCount = -1;
static CGFloat cmKeyboardHeight = 0;
static UIWindow *cmOverlayWindow = nil;
static UIButton *cmFloatButton = nil;
static __weak UIView *cmSavedFirstResponder = nil;

#pragma mark - Windows and responders

static NSArray<UIWindow *> *CMAllWindows(void) {
    NSMutableArray *result = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [result addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return result;
}

static UIWindow *CMKeyWindow(void) {
    NSArray<UIWindow *> *wins = CMAllWindows();
    for (UIWindow *w in wins) {
        if (w == cmOverlayWindow) continue;
        if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in wins) {
        if (w != cmOverlayWindow) return w;
    }
    return nil;
}

static UIWindowScene *CMActiveScene(void) {
    UIWindow *kw = CMKeyWindow();
    if (kw.windowScene) return kw.windowScene;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

static UIView *CMFindFirstResponder(UIView *view) {
    if (!view) return nil;
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        UIView *f = CMFindFirstResponder(sub);
        if (f) return f;
    }
    return nil;
}

static UIView *CMFindAnyFirstResponder(void) {
    for (UIWindow *w in CMAllWindows()) {
        if (w == cmOverlayWindow) continue;
        UIView *fr = CMFindFirstResponder(w);
        if (fr) return fr;
    }
    return nil;
}

static void CMPasteText(NSString *text) {
    if (text.length == 0) return;

    UIView *target = cmSavedFirstResponder;
    if (!target || !target.window) {
        target = CMFindAnyFirstResponder();
    }

    if (target) {
        if (!target.isFirstResponder) {
            [target becomeFirstResponder];
        }
        if ([target conformsToProtocol:@protocol(UIKeyInput)]) {
            [(id<UIKeyInput>)target insertText:text];
            return;
        }
    }

    // Fallback: system paste through our own pasteboard write
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    [pb setString:text];
    cmOwnChangeCount = pb.changeCount;
    [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
}

#pragma mark - Storage

static NSArray<NSString *> *CMStorePaths(void) {
    static NSArray<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *arr = [NSMutableArray array];
        NSArray<NSString *> *logicals = @[
            @"/var/mobile/Library/CopyMody/history2.json",
            @"/var/mobile/Library/Preferences/com.mody.copymody.history2.json"
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *logical in logicals) {
            NSString *jb = jbroot(logical);
            if (jb.length && ![arr containsObject:jb]) [arr addObject:jb];
            if (![arr containsObject:logical]) [arr addObject:logical];
        }
        for (NSString *p in arr) {
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        }
        paths = [arr copy];
    });
    return paths;
}

static NSDictionary *CMParseStore(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;
    NSArray *raw = dict[@"items"];
    if (![raw isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray *clean = [NSMutableArray array];
    for (id it in raw) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)it;
        NSString *t = d[@"text"];
        if (![t isKindOfClass:[NSString class]] || t.length == 0) continue;
        [clean addObject:d];
    }

    NSNumber *u = dict[@"updated"];
    double updated = [u isKindOfClass:[NSNumber class]] ? u.doubleValue : 0;
    return @{ @"updated": @(updated), @"items": clean };
}

@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItem:(NSDictionary *)item;
- (void)clearAll;
- (void)cm_openPanel;
@end

static void CMPresentHistory(void);
static void CMClosePanel(void);

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
    NSTimeInterval _updated;
    NSUserDefaults *_defaults;
    dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
    static CMHistoryManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CMHistoryManager alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        _ioQueue = dispatch_queue_create("com.mody.copymody.io", DISPATCH_QUEUE_SERIAL);
        _items = [NSMutableArray array];
        _updated = 0;
        [self reloadIfNewer];
    }
    return self;
}

// Loads the newest store (files or defaults). In-memory state wins unless something newer exists.
- (void)reloadIfNewer {
    NSTimeInterval bestUpdated = _updated;
    NSArray *bestItems = nil;

    for (NSString *path in CMStorePaths()) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length == 0) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *store = CMParseStore(obj);
        if (!store) continue;
        NSTimeInterval u = [store[@"updated"] doubleValue];
        if (u > bestUpdated) {
            bestUpdated = u;
            bestItems = store[@"items"];
        }
    }

    NSDictionary *defStore = CMParseStore([_defaults dictionaryForKey:kStoreKey]);
    if (defStore) {
        NSTimeInterval u = [defStore[@"updated"] doubleValue];
        if (u > bestUpdated) {
            bestUpdated = u;
            bestItems = defStore[@"items"];
        }
    }

    if (bestItems) {
        _items = [bestItems mutableCopy];
        _updated = bestUpdated;
    }
}

- (void)persist {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    _updated = MAX(now, _updated + 0.000001);

    NSDictionary *store = @{ @"updated": @(_updated), @"items": [_items copy] };
    NSUserDefaults *defs = _defaults;
    dispatch_async(_ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:store options:0 error:nil];
        if (data) {
            for (NSString *path in CMStorePaths()) {
                [data writeToFile:path atomically:YES];
            }
        }
        [defs setObject:store forKey:kStoreKey];
    });
}

- (NSArray<NSDictionary *> *)allItems {
    [self reloadIfNewer];
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) return;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    if (t.length > 8000) {
        NSRange r = [t rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 8000)];
        t = [t substringWithRange:r];
    }

    [self reloadIfNewer];
    if (_items.count > 0 && [_items.firstObject[@"text"] isEqualToString:t]) return;

    for (NSInteger i = (NSInteger)_items.count - 1; i >= 0; i--) {
        if ([_items[i][@"text"] isEqualToString:t]) [_items removeObjectAtIndex:i];
    }

    NSInteger now = (NSInteger)[[NSDate date] timeIntervalSince1970];
    [_items insertObject:@{ @"text": t, @"timestamp": @(now) } atIndex:0];
    while ((NSInteger)_items.count > kMaxHistoryItems) [_items removeLastObject];
    [self persist];
}

- (void)removeItem:(NSDictionary *)item {
    if (!item) return;
    [self reloadIfNewer];
    NSString *target = item[@"text"];
    NSUInteger idx = [_items indexOfObjectPassingTest:^BOOL(NSDictionary *o, NSUInteger i, BOOL *stop) {
        return [o[@"text"] isEqualToString:target];
    }];
    if (idx == NSNotFound) return;
    [_items removeObjectAtIndex:idx];
    [self persist];
}

- (void)clearAll {
    [_items removeAllObjects];
    [self persist];
}

- (void)cm_openPanel {
    CMPresentHistory();
}

@end

#pragma mark - Capture

static NSInteger CMGeneralChangeCount(void) {
    return [UIPasteboard generalPasteboard].changeCount;
}

static void CMCaptureAfterChange(NSInteger before) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger cc = pb.changeCount;
    if (cc == before || cc == cmLastCaptured || cc == cmOwnChangeCount) return;
    cmLastCaptured = cc;
    if (!pb.hasStrings) return;
    NSString *s = pb.string;
    if (s.length > 0) [[CMHistoryManager shared] addText:s];
}

static void CMScheduleCapture(NSInteger before) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CMCaptureAfterChange(before);
    });
}

#pragma mark - Panel UI

@interface CMHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation CMHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];

    UIButton *dim = [UIButton buttonWithType:UIButtonTypeCustom];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    [dim addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:dim];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"CopyMody";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"مسح الكل" forState:UIControlStateNormal];
    [clearBtn addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    clearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:clearBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"إغلاق" forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:closeBtn];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.estimatedRowHeight = 56;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"لا يوجد عناصر\nانسخ نصاً ثم افتح القائمة";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 2;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.emptyLabel];

    NSMutableArray<NSLayoutConstraint *> *cons = [NSMutableArray array];
    [cons addObjectsFromArray:@[
        [dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],

        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [clearBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-12],
        [closeBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [self.tableView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.tableView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor]
    ]];

    // Keep the keyboard visible: card sits above it when it is showing
    if (cmKeyboardHeight > 40) {
        [cons addObject:[card.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                                          constant:-(cmKeyboardHeight + 10)]];
    } else {
        [cons addObject:[card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]];
    }
    NSLayoutConstraint *h = [card.heightAnchor constraintEqualToConstant:380];
    h.priority = UILayoutPriorityDefaultHigh;
    [cons addObject:h];

    [NSLayoutConstraint activateConstraints:cons];

    [self reload];
}

- (void)reload {
    self.items = [[CMHistoryManager shared] allItems];
    self.emptyLabel.hidden = self.items.count > 0;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *item = self.items[ip.row];
    cell.textLabel.numberOfLines = 3;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.text = item[@"text"];

    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateStyle = NSDateFormatterShortStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
    });
    cell.detailTextLabel.text = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"timestamp"] doubleValue]]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:NO];
    if (ip.row >= (NSInteger)self.items.count) return;
    NSString *text = self.items[ip.row][@"text"];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return;

    [self close];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CMPasteText(text);
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *item = (ip.row < (NSInteger)self.items.count) ? self.items[ip.row] : nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"حذف"
                                                                    handler:^(__unused UIContextualAction *a, __unused UIView *v, void (^done)(BOOL)) {
        [[CMHistoryManager shared] removeItem:item];
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)clearAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"مسح السجل"
                                                               message:@"حذف الكل؟"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [[CMHistoryManager shared] clearAll];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)close {
    if (self.onClose) self.onClose();
}

@end

static void CMClosePanel(void) {
    UIWindow *w = cmOverlayWindow;
    cmOverlayWindow = nil;
    if (w) {
        w.hidden = YES;
        w.rootViewController = nil;
    }
}

static void CMPresentHistory(void) {
    if (cmOverlayWindow) return;

    UIWindowScene *scene = CMActiveScene();
    if (!scene) return;

    // Remember the text field BEFORE the panel appears
    cmSavedFirstResponder = CMFindAnyFirstResponder();

    UIWindow *win = [[UIWindow alloc] initWithWindowScene:scene];
    win.windowLevel = UIWindowLevelAlert + 100;
    win.backgroundColor = [UIColor clearColor];

    CMHistoryViewController *vc = [[CMHistoryViewController alloc] init];
    vc.onClose = ^{ CMClosePanel(); };
    win.rootViewController = vc;

    cmOverlayWindow = win;
    // Visible but NOT key: the keyboard and the text field keep focus
    win.hidden = NO;
}

#pragma mark - Floating button

static void CMRemoveButtons(void) {
    for (UIWindow *w in CMAllWindows()) {
        for (UIView *v in [w.subviews copy]) {
            if (v.tag == kButtonTag) [v removeFromSuperview];
        }
    }
    cmFloatButton = nil;
}

static void CMShowButton(CGRect kb) {
    UIWindow *kw = CMKeyWindow();
    if (!kw) return;

    CMRemoveButtons();

    CGFloat s = 40, pad = 8;
    CGFloat x = kb.origin.x + kb.size.width - s - pad;
    CGFloat y = kb.origin.y - s - 8;
    if (kb.size.height < 50 || y < 40) {
        x = kw.bounds.size.width - s - 12;
        y = kw.bounds.size.height - 120;
    }

    cmFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    cmFloatButton.tag = kButtonTag;
    cmFloatButton.frame = CGRectMake(x, y, s, s);
    cmFloatButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:0.92 alpha:1.0];
    cmFloatButton.layer.cornerRadius = s / 2.0;
    cmFloatButton.layer.shadowOpacity = 0.35;
    cmFloatButton.layer.shadowRadius = 4;
    cmFloatButton.layer.shadowOffset = CGSizeMake(0, 2);
    [cmFloatButton setTitle:@"CM" forState:UIControlStateNormal];
    [cmFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cmFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];

    [cmFloatButton addTarget:[CMHistoryManager shared]
                      action:@selector(cm_openPanel)
            forControlEvents:UIControlEventTouchUpInside];

    [kw addSubview:cmFloatButton];
    [kw bringSubviewToFront:cmFloatButton];
}

#pragma mark - Hooks

%hook UIPasteboard

- (void)setString:(NSString *)string {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setStrings:(NSArray *)strings {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setItems:(NSArray *)items {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)addItems:(NSArray *)items {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setItemProviders:(NSArray *)itemProviders localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setObjects:(NSArray *)objects {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)setObjects:(NSArray *)objects localOnly:(BOOL)localOnly expirationDate:(NSDate *)expirationDate {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

%end

%hook UIResponder

- (void)copy:(id)sender {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

- (void)cut:(id)sender {
    NSInteger before = CMGeneralChangeCount();
    %orig;
    CMScheduleCapture(before);
}

%end

%ctor {
    @autoreleasepool {
        // Never load twice in the same process
        if (getenv("COPYMODY_LOADED")) return;

        // Apps only: skip daemons, extensions and SpringBoard
        NSBundle *mb = [NSBundle mainBundle];
        if (![mb.bundlePath hasSuffix:@".app"]) return;
        if ([mb.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        setenv("COPYMODY_LOADED", "1", 1);

        %init;

        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
            UIWindow *kw = CMKeyWindow();
            if (kw) kb = [kw convertRect:kb fromWindow:nil];
            if (kb.size.height < 1) return;
            cmKeyboardHeight = kw ? MAX(0, kw.bounds.size.height - kb.origin.y) : kb.size.height;
            CMShowButton(kb);
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            cmKeyboardHeight = 0;
            if (!cmOverlayWindow) CMRemoveButtons();
        }];

        NSLog(@"[CopyMody] v0.1.12 loaded");
    }
}
