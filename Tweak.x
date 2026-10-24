#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kHistoryFileName = @"com.mody.copymody.history.json";
static NSInteger const kMaxHistoryItems = 50;
static NSInteger const kButtonTag = 88442211;

static BOOL cmIsSaving = NO;
static NSTimeInterval cmLastSaveTime = 0;

// ==================== Helpers ====================
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
    return CMAllWindows().firstObject;
}

static NSString *CMHistoryPath(void) {
    NSString *pref = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", kHistoryFileName];
    NSString *lib  = [NSString stringWithFormat:@"/var/mobile/Library/CopyMody/%@", kHistoryFileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:pref.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:lib.stringByDeletingLastPathComponent  withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm fileExistsAtPath:pref]) return pref;
    if ([fm fileExistsAtPath:lib])  return lib;
    if ([@"[]" writeToFile:pref atomically:YES encoding:NSUTF8StringEncoding error:nil]) return pref;
    if ([@"[]" writeToFile:lib  atomically:YES encoding:NSUTF8StringEncoding error:nil]) return lib;
    return [NSTemporaryDirectory() stringByAppendingPathComponent:kHistoryFileName];
}

static NSString *CMSelectedTextFromView(UIView *view) {
    if (!view) return nil;
    if ([view conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)view;
        UITextRange *range = input.selectedTextRange;
        if (range && !range.isEmpty) {
            return [input textInRange:range];
        }
    }
    return nil;
}

// ==================== History Manager ====================
@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)clearAll;
@end

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
    NSString *_path;
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
        _path = CMHistoryPath();
        _items = [NSMutableArray array];
        _ioQueue = dispatch_queue_create("com.mody.copymody.io", DISPATCH_QUEUE_SERIAL);
        NSData *data = [NSData dataWithContentsOfFile:_path];
        if (data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSArray class]]) _items = [obj mutableCopy];
        }
        NSLog(@"[CopyMody] path=%@ items=%lu", _path, (unsigned long)_items.count);
    }
    return self;
}

- (void)saveAsync {
    NSArray *snap = [_items copy];
    NSString *path = _path;
    dispatch_async(_ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snap options:0 error:nil];
        if (data) [data writeToFile:path atomically:YES];
    });
}

- (NSArray<NSDictionary *> *)allItems {
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (!text) return;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    if (t.length > 8000) t = [t substringToIndex:8000];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - cmLastSaveTime < 0.25) {
        // still allow if different text
        if (_items.count > 0 && [_items.firstObject[@"text"] isEqualToString:t]) return;
    }
    cmLastSaveTime = now;

    if (_items.count > 0 && [_items.firstObject[@"text"] isEqualToString:t]) return;

    NSDictionary *entry = @{
        @"text" : t,
        @"timestamp" : @((NSInteger)now)
    };
    [_items insertObject:entry atIndex:0];
    while ((NSInteger)_items.count > kMaxHistoryItems) [_items removeLastObject];
    [self saveAsync];
    NSLog(@"[CopyMody] saved: %@ (%lu)", [t substringToIndex:MIN((NSUInteger)40, t.length)], (unsigned long)_items.count);
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

// ==================== UI ====================
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
    self.emptyLabel.text = @"لا يوجد عناصر\nحدّد نصاً ثم اضغط نسخ";
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

    [self reload];
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

    UIView *fr = nil;
    UIWindow *kw = CMKeyWindow();
    fr = [self findFR:kw];
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

- (UIView *)findFR:(UIView *)v {
    if (!v) return nil;
    if (v.isFirstResponder) return v;
    for (UIView *s in v.subviews) {
        UIView *f = [self findFR:s];
        if (f) return f;
    }
    return nil;
}

@end

// ==================== Button ====================
static UIWindow *cmOverlayWindow = nil;
static UIButton *cmFloatButton = nil;

static void CMRemoveButtons(void) {
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
        if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return;

    cmOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    cmOverlayWindow.windowLevel = UIWindowLevelAlert + 50;
    cmOverlayWindow.backgroundColor = [UIColor clearColor];

    CMHistoryViewController *vc = [[CMHistoryViewController alloc] init];
    vc.onDismiss = ^{
        cmOverlayWindow.hidden = YES;
        cmOverlayWindow.rootViewController = nil;
        cmOverlayWindow = nil;
    };
    cmOverlayWindow.rootViewController = vc;
    [cmOverlayWindow makeKeyAndVisible];
}

static void CMShowButton(CGRect kb) {
    UIWindow *kw = CMKeyWindow();
    if (!kw) return;
    CMRemoveButtons();

    CGFloat s = 36, pad = 6;
    CGFloat x = kb.origin.x + kb.size.width - s - pad - 4;
    CGFloat y = kb.origin.y + kb.size.height - s - pad - 4;
    if (kb.size.height < 50) {
        x = kw.bounds.size.width - s - 12;
        y = kw.bounds.size.height - 90;
    }

    cmFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    cmFloatButton.tag = kButtonTag;
    cmFloatButton.frame = CGRectMake(x, y, s, s);
    cmFloatButton.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:0.92 alpha:0.92];
    cmFloatButton.layer.cornerRadius = s/2;
    cmFloatButton.layer.shadowOpacity = 0.25;
    cmFloatButton.layer.shadowRadius = 3;
    cmFloatButton.layer.shadowOffset = CGSizeMake(0, 1);
    [cmFloatButton setTitle:@"📋" forState:UIControlStateNormal];
    cmFloatButton.titleLabel.font = [UIFont systemFontOfSize:17];
    [cmFloatButton addAction:[UIAction actionWithHandler:^(__unused UIAction *a) { CMPresentHistory(); }] forControlEvents:UIControlEventTouchUpInside];
    [kw addSubview:cmFloatButton];
}

// ==================== Capture selected text on Copy ====================

static void CMHandleCopyFromResponder(id self_) {
    if (cmIsSaving) return;
    if (![self_ isKindOfClass:[UIView class]]) return;
    NSString *sel = CMSelectedTextFromView((UIView *)self_);
    if (sel.length > 0) {
        [[CMHistoryManager shared] addText:sel];
    }
}

%hook UIResponder

- (void)copy:(id)sender {
    CMHandleCopyFromResponder(self);
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

// Backup: pasteboard hooks (no .string reads)
%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    if (!cmIsSaving && string.length > 0) {
        [[CMHistoryManager shared] addText:string];
    }
}

- (void)setItems:(NSArray *)items {
    %orig;
    if (cmIsSaving || items.count == 0) return;
    for (NSDictionary *item in items) {
        id val = item[@"public.utf8-plain-text"] ?: item[@"public.plain-text"];
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

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        UIWindow *kw = CMKeyWindow();
        if (kw) kb = [kw convertRect:kb fromWindow:nil];
        CMShowButton(kb);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
        CMRemoveButtons();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
        CMRemoveButtons();
    }];
    NSLog(@"[CopyMody] v0.1.5 loaded");
}
