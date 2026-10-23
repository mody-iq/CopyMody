#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ==================== Constants ====================
static NSString * const kHistoryPath = @"/var/mobile/Library/CopyMody/history.plist";
static NSInteger const kMaxHistoryItems = 50;

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

// ==================== History Manager ====================
@interface CMHistoryManager : NSObject
+ (instancetype)shared;
- (NSArray<NSDictionary *> *)allItems;
- (void)addText:(NSString *)text;
- (void)removeItemAtIndex:(NSInteger)index;
- (void)clearAll;
- (void)save;
@end

@implementation CMHistoryManager {
    NSMutableArray<NSDictionary *> *_items;
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
        NSString *dir = [kHistoryPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        NSArray *saved = [NSArray arrayWithContentsOfFile:kHistoryPath];
        _items = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSDictionary *> *)allItems {
    return [_items copy];
}

- (void)addText:(NSString *)text {
    if (!text || text.length == 0) return;

    if (_items.count > 0) {
        NSString *last = _items.firstObject[@"text"];
        if ([last isEqualToString:text]) return;
    }

    NSDictionary *entry = @{
        @"text"      : text,
        @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    };

    [_items insertObject:entry atIndex:0];

    while (_items.count > kMaxHistoryItems) {
        [_items removeLastObject];
    }

    [self save];
}

- (void)removeItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_items.count) return;
    [_items removeObjectAtIndex:index];
    [self save];
}

- (void)clearAll {
    [_items removeAllObjects];
    [self save];
}

- (void)save {
    [_items writeToFile:kHistoryPath atomically:YES];
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
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
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

// ==================== Keyboard Button + Presenter ====================
static UIWindow *cmOverlayWindow = nil;
static UIButton *cmKeyboardButton = nil;

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

static void CMAddKeyboardButton(void) {
    UIWindow *keyboardWindow = nil;

    for (UIWindow *w in CMAllWindows()) {
        NSString *name = NSStringFromClass(w.class);
        if ([name containsString:@"Keyboard"] || [name containsString:@"UIRemoteKeyboard"]) {
            keyboardWindow = w;
            break;
        }
    }

    if (!keyboardWindow) {
        for (UIWindow *w in CMAllWindows()) {
            if (w.windowLevel > UIWindowLevelNormal + 1) {
                keyboardWindow = w;
                break;
            }
        }
    }
    if (!keyboardWindow) return;

    if (cmKeyboardButton && cmKeyboardButton.superview) return;

    cmKeyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cmKeyboardButton setTitle:@"📋" forState:UIControlStateNormal];
    cmKeyboardButton.titleLabel.font = [UIFont systemFontOfSize:22];
    cmKeyboardButton.backgroundColor = [[UIColor systemGray5Color] colorWithAlphaComponent:0.9];
    cmKeyboardButton.layer.cornerRadius = 8;
    cmKeyboardButton.clipsToBounds = YES;

    [cmKeyboardButton addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        CMPresentHistory();
    }] forControlEvents:UIControlEventTouchUpInside];

    CGFloat kbWidth = keyboardWindow.bounds.size.width;
    CGFloat kbHeight = keyboardWindow.bounds.size.height;
    CGFloat margin = 8;
    cmKeyboardButton.frame = CGRectMake(kbWidth - 36 - margin - 40,
                                        kbHeight - 36 - margin - 10,
                                        36, 36);

    [keyboardWindow addSubview:cmKeyboardButton];
}

static void CMRemoveKeyboardButton(void) {
    if (cmKeyboardButton) {
        [cmKeyboardButton removeFromSuperview];
        cmKeyboardButton = nil;
    }
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
    for (NSDictionary *item in items) {
        id str = item[@"public.utf8-plain-text"] ?: item[@"public.plain-text"] ?: item[@"public.text"];
        if ([str isKindOfClass:[NSString class]] && [(NSString *)str length] > 0) {
            [[CMHistoryManager shared] addText:(NSString *)str];
            break;
        }
        if ([str isKindOfClass:[NSData class]]) {
            NSString *decoded = [[NSString alloc] initWithData:(NSData *)str encoding:NSUTF8StringEncoding];
            if (decoded.length > 0) {
                [[CMHistoryManager shared] addText:decoded];
                break;
            }
        }
    }
}

%end

%hook UIKeyboardImpl

- (void)showKeyboard {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        CMAddKeyboardButton();
    });
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        CMAddKeyboardButton();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        CMRemoveKeyboardButton();
    }];

    NSLog(@"[CopyMody] Loaded – monitoring clipboard + keyboard button ready");
}
