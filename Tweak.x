#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>

#include <roothide.h>

static NSString * const kSuiteName = @"com.mody.copymody.history";
static NSString * const kHistoryKey = @"items";
static const char *kDarwinName = "com.mody.copymody.history.changed";
static NSInteger const kMaxHistoryItems = 50;
static NSInteger const kButtonTag = 88442211;

static BOOL cmIsSaving = NO;
static NSTimeInterval cmLastCapture = 0;
static UIWindow *cmOverlayWindow = nil;
static UIButton *cmFloatButton = nil;
static BOOL cmPresenting = NO;

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
    for (UIWindow *w in CMAllWindows()) {
        if (w.isKeyWindow) return w;
    }
    NSArray *wins = CMAllWindows();
    return wins.count ? wins.firstObject : nil;
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

static NSString *CMSelectedTextFromView(UIView *view) {
    if (!view) return nil;
    if ([view conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)view;
        UITextRange *range = input.selectedTextRange;
        if (range && !range.isEmpty) {
            NSString *t = [input textInRange:range];
            if (t.length > 0) return t;
        }
    }
    if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.selectedRange.length > 0 && tv.text.length > 0) {
            NSRange r = tv.selectedRange;
            if (NSMaxRange(r) <= tv.text.length)
                return [tv.text substringWithRange:r];
        }
    }
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        UITextRange *r = tf.selectedTextRange;
        if (r && !r.isEmpty) return [tf textInRange:r];
    }
    return nil;
}

static NSString *CMFindAnySelectedText(UIView *view) {
    if (!view) return nil;
    NSString *t = CMSelectedTextFromView(view);
    if (t.length > 0) return t;
    for (UIView *sub in view.subviews) {
        t = CMFindAnySelectedText(sub);
        if (t.length > 0) return t;
    }
    return nil;
}

static NSString *CMCaptureSelectionNow(void) {
    for (UIWindow *w in CMAllWindows()) {
        UIView *fr = CMFindFirstResponder(w);
        NSString *t = CMSelectedTextFromView(fr);
        if (t.length > 0) return t;
    }
    for (UIWindow *w in CMAllWindows()) {
        NSString *t = CMFindAnySelectedText(w);
        if (t.length > 0) return t;
    }
    return nil;
}

static NSArray<NSString *> *CMHistoryPaths(void) {
    NSString *logical1 = @"/var/mobile/Library/Preferences/com.mody.copymody.history.json";
    NSString *logical2 = @"/var/mobile/Library/CopyMody/history.json";
    NSString *jb1 = jbroot(logical1);
    NSString *jb2 = jbroot(logical2);
    if (!jb1.length) jb1 = logical1;
    if (!jb2.length) jb2 = logical2;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in @[jb1, logical1, jb2, logical2]) {
        [fm createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return @[jb1, logical1, jb2, logical2];
}

@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)clearAll;
- (void)cm_openPanel;
@end

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
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
        [self loadFromDisk];
    }
    return self;
}

- (void)loadFromDisk {
    for (NSString *path in CMHistoryPaths()) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSArray class]] && [obj count] > 0) {
            _items = [obj mutableCopy];
            return;
        }
    }
    NSArray *arr = [_defaults arrayForKey:kHistoryKey];
    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0)
        _items = [arr mutableCopy];
}

- (void)persist {
    NSArray *snap = [_items copy];
    NSUserDefaults *defs = _defaults;
    dispatch_async(_ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
        if (data) {
            for (NSString *path in CMHistoryPaths())
                [data writeToFile:path atomically:YES];
        }
        [defs setObject:snap forKey:kHistoryKey];
        [defs synchronize];
        notify_post(kDarwinName);
    });
}

- (NSArray<NSDictionary *> *)allItems {
    [self loadFromDisk];
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (!text || cmIsSaving) return;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    if (t.length > 8000) t = [t substringToIndex:8000];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - cmLastCapture < 0.2 && _items.count > 0 &&
        [_items.firstObject[@"text"] isEqualToString:t]) return;
    cmLastCapture = now;

    [self loadFromDisk];
    if (_items.count > 0 && [_items.firstObject[@"text"] isEqualToString:t]) return;

    [_items insertObject:@{ @"text": t, @"timestamp": @((NSInteger)now) } atIndex:0];
    while ((NSInteger)_items.count > kMaxHistoryItems) [_items removeLastObject];
    [self persist];
}

- (void)removeItemAtIndex:(NSInteger)index {
    [self loadFromDisk];
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items removeObjectAtIndex:index];
    [self persist];
}

- (void)clearAll {
    [_items removeAllObjects];
    [self persist];
}

@end

@interface CMHistoryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation CMHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];

    UIView *card = [[UIView alloc] init];
    card.tag = 99001;
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

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.heightAnchor constraintEqualToConstant:400],
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

    // Close only when tapping dimmed area (not the card)
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)];
    [self.view addGestureRecognizer:bgTap];

    [self reload];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *sel = CMCaptureSelectionNow();
        if (sel.length > 0) {
            [[CMHistoryManager shared] addText:sel];
            [weakSelf reload];
        }
    });
}

- (void)bgTapped:(UITapGestureRecognizer *)gr {
    CGPoint p = [gr locationInView:self.view];
    UIView *card = [self.view viewWithTag:99001];
    if (card && CGRectContainsPoint(card.frame, p)) return;
    [self close];
}

- (void)reload {
    self.items = [[CMHistoryManager shared] allItems];
    self.emptyLabel.hidden = self.items.count > 0;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *item = self.items[ip.row];
    cell.textLabel.numberOfLines = 3;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.text = item[@"text"];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateStyle = NSDateFormatterShortStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"timestamp"] doubleValue]]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *text = self.items[ip.row][@"text"];
    if (!text) return;
    cmIsSaving = YES;
    [[UIPasteboard generalPasteboard] setString:text];
    cmIsSaving = NO;
    UIView *fr = CMFindFirstResponder(CMKeyWindow());
    if ([fr isKindOfClass:[UITextField class]]) [(UITextField *)fr insertText:text];
    else if ([fr isKindOfClass:[UITextView class]]) [(UITextView *)fr insertText:text];
    else if ([fr respondsToSelector:@selector(paste:)]) [fr paste:nil];
    [self close];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"حذف" handler:^(__unused UIContextualAction *a, __unused UIView *v, void (^done)(BOOL)) {
        [[CMHistoryManager shared] removeItemAtIndex:ip.row];
        [self reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

- (void)clearAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"مسح السجل" message:@"حذف الكل؟" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"مسح" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x) {
        [[CMHistoryManager shared] clearAll];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onDismiss) self.onDismiss();
    }];
}

@end

static void CMRemoveButtons(void) {
    for (UIWindow *w in CMAllWindows()) {
        for (UIView *v in [w.subviews copy]) {
            if (v.tag == kButtonTag) [v removeFromSuperview];
        }
    }
    if (cmFloatButton) {
        [cmFloatButton removeFromSuperview];
        cmFloatButton = nil;
    }
}

static void CMPresentHistory(void) {
    if (cmPresenting) return;
    if (cmOverlayWindow) return; // already open — do not toggle-close

    cmPresenting = YES;

    UIWindowScene *scene = CMActiveScene();
    if (!scene) {
        cmPresenting = NO;
        NSLog(@"[CopyMody] no scene");
        return;
    }

    NSString *sel = CMCaptureSelectionNow();
    if (sel.length > 0) [[CMHistoryManager shared] addText:sel];

    cmOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    cmOverlayWindow.windowLevel = UIWindowLevelAlert + 100;
    cmOverlayWindow.backgroundColor = [UIColor clearColor];
    cmOverlayWindow.userInteractionEnabled = YES;

    CMHistoryViewController *vc = [[CMHistoryViewController alloc] init];
    vc.onDismiss = ^{
        cmOverlayWindow.hidden = YES;
        cmOverlayWindow.rootViewController = nil;
        cmOverlayWindow = nil;
        cmPresenting = NO;
    };
    cmOverlayWindow.rootViewController = vc;
    [cmOverlayWindow makeKeyAndVisible];

    // Release presenting lock shortly after show
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        cmPresenting = NO;
    });

    NSLog(@"[CopyMody] panel shown");
}

@implementation CMHistoryManager (Button)
- (void)cm_openPanel {
    CMPresentHistory();
}
@end

static void CMShowButton(CGRect kb) {
    UIWindow *kw = CMKeyWindow();
    if (!kw) return;

    // If a valid button already exists on this key window, just update frame
    if (cmFloatButton && cmFloatButton.superview == kw) {
        CGFloat s = 40, pad = 8;
        CGFloat x = kb.origin.x + kb.size.width - s - pad;
        CGFloat y = kb.origin.y - s - 8;
        if (kb.size.height < 50 || y < 40) {
            x = kw.bounds.size.width - s - 12;
            y = kw.bounds.size.height - 120;
        }
        cmFloatButton.frame = CGRectMake(x, y, s, s);
        [kw bringSubviewToFront:cmFloatButton];
        return;
    }

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

    // ONE handler only
    [cmFloatButton addTarget:[CMHistoryManager shared]
                      action:@selector(cm_openPanel)
            forControlEvents:UIControlEventTouchUpInside];

    [kw addSubview:cmFloatButton];
    [kw bringSubviewToFront:cmFloatButton];
}

%hook UIPasteboard
- (void)setString:(NSString *)string {
    %orig;
    if (!cmIsSaving && string.length > 0)
        [[CMHistoryManager shared] addText:string];
}
- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig;
    if (!cmIsSaving && strings.count > 0 && [strings.firstObject length] > 0)
        [[CMHistoryManager shared] addText:strings.firstObject];
}
- (void)setItems:(NSArray *)items {
    %orig;
    if (cmIsSaving || items.count == 0) return;
    for (NSDictionary *item in items) {
        id val = item[@"public.utf8-plain-text"] ?: item[@"public.plain-text"] ?: item[@"public.text"];
        if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            [[CMHistoryManager shared] addText:val];
            return;
        }
        if ([val isKindOfClass:[NSData class]]) {
            NSString *s = [[NSString alloc] initWithData:val encoding:NSUTF8StringEncoding];
            if (s.length > 0) { [[CMHistoryManager shared] addText:s]; return; }
        }
    }
}
%end

%hook UIResponder
- (void)copy:(id)sender {
    if (!cmIsSaving && [self isKindOfClass:[UIView class]]) {
        NSString *sel = CMSelectedTextFromView((UIView *)self);
        if (sel.length > 0) [[CMHistoryManager shared] addText:sel];
    }
    %orig;
}
%end

%hook UITextView
- (void)copy:(id)sender {
    NSString *sel = CMSelectedTextFromView(self);
    if (sel.length > 0) [[CMHistoryManager shared] addText:sel];
    %orig;
}
%end

%hook UITextField
- (void)copy:(id)sender {
    NSString *sel = CMSelectedTextFromView(self);
    if (sel.length > 0) [[CMHistoryManager shared] addText:sel];
    %orig;
}
%end

%ctor {
    int token = 0;
    notify_register_dispatch(kDarwinName, &token, dispatch_get_main_queue(), ^(__unused int t) {});

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        UIWindow *kw = CMKeyWindow();
        if (kw) kb = [kw convertRect:kb fromWindow:nil];
        CMShowButton(kb);
    }];

    // Do NOT remove button on WillHide if panel is open (avoids flicker)
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
        if (!cmOverlayWindow) CMRemoveButtons();
    }];

    NSLog(@"[CopyMody] v0.1.10 loaded");
}
