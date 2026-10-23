#import <UIKit/UIKit.h>

%hook UIPasteboard

// Placeholder for future clipboard monitoring hooks
// Will be expanded after first successful build

%end

%ctor {
    NSLog(@"[CopyMody] Loaded successfully");
}
