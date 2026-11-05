#import "AppLog.h"

#import <UIKit/UIKit.h>
#import <os/log.h>

static const NSUInteger RFMaxLines = 1500;

static NSMutableArray<NSString *> *RFLines(void) {
  static NSMutableArray *lines;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lines = [NSMutableArray array]; });
  return lines;
}

void RFAppLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss.SSS";
  });
  os_log(OS_LOG_DEFAULT, "[RF] %{public}@", message);
  NSMutableArray *lines = RFLines();
  @synchronized(lines) {
    [lines addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], message]];
    if (lines.count > RFMaxLines) [lines removeObjectsInRange:NSMakeRange(0, lines.count - RFMaxLines)];
  }
}

static NSString *RFLogText(void) {
  NSMutableArray *lines = RFLines();
  @synchronized(lines) {
    return [lines componentsJoinedByString:@"\n"];
  }
}

@interface UIView (RFDump)
- (NSString *)recursiveDescription;
@end

#pragma mark - Log viewer

@interface RFLogViewController : UIViewController
@property(nonatomic, strong) UITextView *textView;
@end

@implementation RFLogViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"RedditFilter Log";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                    target:self
                                                    action:@selector(close)];
  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                  target:self
                                                  action:@selector(share:)],
    [[UIBarButtonItem alloc] initWithTitle:@"Leeren" style:UIBarButtonItemStylePlain target:self action:@selector(clear)],
    [[UIBarButtonItem alloc] initWithTitle:@"UI" style:UIBarButtonItemStylePlain target:self action:@selector(dumpUI)],
  ];

  self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.textView.editable = NO;
  self.textView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  [self.view addSubview:self.textView];
  [self reload];
}

- (void)reload {
  self.textView.text = RFLogText();
  if (self.textView.text.length) [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length - 1, 1)];
}

- (void)close {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)clear {
  NSMutableArray *lines = RFLines();
  @synchronized(lines) {
    [lines removeAllObjects];
  }
  [self reload];
}

- (void)share:(UIBarButtonItem *)sender {
  UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ RFLogText() ]
                                                                      applicationActivities:nil];
  sheet.popoverPresentationController.barButtonItem = sender;
  [self presentViewController:sheet animated:YES completion:nil];
}

// Class names and frames of the app's own windows: what is on screen right now.
// Label texts are part of it (for example a user name), so look before sharing.
- (void)dumpUI {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if ([window isKindOfClass:NSClassFromString(@"RFLogWindow")]) continue;
      NSString *dump = [window respondsToSelector:@selector(recursiveDescription)] ? [window recursiveDescription]
                                                                                  : window.description;
      RFAppLog(@"[ui] window %@\n%@", window.class, dump.length > 12000 ? [dump substringToIndex:12000] : dump);
    }
  }
  [self reload];
}

@end

#pragma mark - Floating button

@interface RFLogWindow : UIWindow
@end

@implementation RFLogWindow
// Only the button takes touches; everything else reaches the app below.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *view = [super hitTest:point withEvent:event];
  if (view == self || view == self.rootViewController.view) return nil;
  return view;
}
@end

@interface RFLogRootViewController : UIViewController
@end

@implementation RFLogRootViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setTitle:@"RF" forState:UIControlStateNormal];
  [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
  button.backgroundColor = [UIColor colorWithRed:1 green:0.27 blue:0 alpha:0.75];
  button.layer.cornerRadius = 16;
  button.frame = CGRectMake(8, 60, 44, 32);
  button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
  [button addTarget:self action:@selector(openLog) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:button];
}

- (void)openLog {
  if (self.presentedViewController) return;
  UINavigationController *navigation =
      [[UINavigationController alloc] initWithRootViewController:[RFLogViewController new]];
  navigation.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:navigation animated:YES completion:nil];
}
@end

static RFLogWindow *RFWindow;

static void RFShowButton(void) {
  if (RFWindow) return;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
      continue;
    RFWindow = [[RFLogWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    RFWindow.windowLevel = UIWindowLevelAlert + 1;
    RFWindow.rootViewController = [RFLogRootViewController new];
    RFWindow.hidden = NO;
    RFAppLog(@"[log] button shown");
    return;
  }
}

void RFAppLogInstall(void) {
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *note) { RFShowButton(); }];
}
