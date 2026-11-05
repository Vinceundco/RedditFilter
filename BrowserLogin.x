// BrowserLogin.x
//
// Logs in through reddit.com in a web view instead of through the app's own
// login requests. Reddit's servers refuse the app's login
// (/auth/v2/login/password answers 401) on some networks, because a re-signed
// app has no valid App Attest proof; the website has no such check.
//
// The app reads the cookie `reddit_session` from the answer to its login
// request and exchanges it for a token (/auth/v2/oauth/access-token/session).
// So:
//
//   1. when the app's login screen appears (or "Continue with Google/Apple" is
//      tapped, which can't work in a re-signed app), a web view with
//      reddit.com/login opens; email, Google, Apple and two-factor all work there,
//   2. the cookie from that login is kept for ten minutes,
//   3. the login screen is filled with dummy values and submitted for you; the
//      app's login request is answered with the cookie and never leaves the device.
//
// Everything that happens is written to the in-app log (AppLog.h).
// Switch off with RF_NO_BROWSER_LOGIN=1 in the environment.

#import <AuthenticationServices/AuthenticationServices.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "AppLog.h"

static NSString *const RFSessionCookieName = @"reddit_session";
static const NSTimeInterval RFCookieLifetime = 600;

#pragma mark - Cookie kept after a web login

static NSArray<NSHTTPCookie *> *RFCachedCookies;
static NSDate *RFCachedAt;
static NSDate *RFUsedAt;

static BOOL RFHasFreshCookies(void) {
  if (!RFCachedCookies || !RFCachedAt) return NO;
  if (-[RFCachedAt timeIntervalSinceNow] > RFCookieLifetime) return NO;
  // A login request was answered a while ago: that login is over.
  if (RFUsedAt && -[RFUsedAt timeIntervalSinceNow] > 30) return NO;
  return YES;
}

#pragma mark - Web view

typedef void (^RFBrowserLoginCompletion)(NSArray<NSHTTPCookie *> *cookies);

@interface RFBrowserLoginController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) RFBrowserLoginCompletion completion;
@end

@implementation RFBrowserLoginController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Reddit";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                    target:self
                                                    action:@selector(cancel)];

  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  // Never reuse an earlier web session: its cookie would log in without asking.
  configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
  self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.webView.navigationDelegate = self;
  self.webView.UIDelegate = self;
  // Google refuses sign-in from embedded web views that don't look like Safari.
  self.webView.customUserAgent =
      @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      @"(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
  [self.view addSubview:self.webView];
  [configuration.websiteDataStore.httpCookieStore addObserver:self];
  [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/login/"]]];
}

- (void)finishWithCookies:(NSArray<NSHTTPCookie *> *)cookies {
  RFBrowserLoginCompletion completion = self.completion;
  if (!completion) return;
  self.completion = nil;
  [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
  [self dismissViewControllerAnimated:YES completion:^{ completion(cookies); }];
}

- (void)cancel {
  RFAppLog(@"[web] cancelled by user");
  [self finishWithCookies:nil];
}

- (void)checkCookies {
  if (!self.completion) return;
  [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
    for (NSHTTPCookie *cookie in cookies)
      if ([cookie.name isEqualToString:RFSessionCookieName] && [cookie.domain hasSuffix:@"reddit.com"] &&
          cookie.value.length) {
        RFAppLog(@"[web] logged in (cookie %@ found)", RFSessionCookieName);
        [self finishWithCookies:cookies];
        return;
      }
  }];
}

- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore {
  [self checkCookies];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  RFAppLog(@"[web] loaded %@%@", webView.URL.host, webView.URL.path);
  [self checkCookies];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  RFAppLog(@"[web] failed %@ %ld", error.domain, (long)error.code);
}

// Sign-in with Google or Apple opens a pop-up window; show it in the same view.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  RFAppLog(@"[web] pop-up %@%@", navigationAction.request.URL.host, navigationAction.request.URL.path);
  [webView loadRequest:navigationAction.request];
  return nil;
}

@end

#pragma mark - Presenting

static UIViewController *RFTopViewController(void) {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
      continue;
    for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
      if (candidate.isKeyWindow) window = candidate;
  }
  UIViewController *controller = window.rootViewController;
  while (controller.presentedViewController) controller = controller.presentedViewController;
  return controller;
}

static NSMutableArray<RFBrowserLoginCompletion> *RFWaiting;
static BOOL RFLoginShown;
static NSDate *RFLoginClosedAt;

// Calls completion with the cookies (kept from an earlier login if fresh), or
// nil if the login was cancelled. All requests that arrive while the web view
// is open wait for the same login.
static void RFRunBrowserLogin(RFBrowserLoginCompletion completion) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (RFHasFreshCookies()) {
      RFAppLog(@"[web] using the cookie from the earlier login");
      completion(RFCachedCookies);
      return;
    }
    if (!RFWaiting) RFWaiting = [NSMutableArray array];
    [RFWaiting addObject:completion];
    if (RFLoginShown) return;

    UIViewController *top = RFTopViewController();
    if (!top) {
      RFAppLog(@"[web] no view controller to present the login on");
      NSArray *waiting = [RFWaiting copy];
      [RFWaiting removeAllObjects];
      for (RFBrowserLoginCompletion done in waiting) done(nil);
      return;
    }
    RFLoginShown = YES;
    RFAppLog(@"[web] opening login over %@", top.class);
    RFBrowserLoginController *login = [RFBrowserLoginController new];
    login.completion = ^(NSArray<NSHTTPCookie *> *cookies) {
      RFLoginShown = NO;
      RFLoginClosedAt = [NSDate date];
      if (cookies.count) {
        RFCachedCookies = cookies;
        RFCachedAt = [NSDate date];
        RFUsedAt = nil;
      }
      NSArray *waiting = [RFWaiting copy];
      [RFWaiting removeAllObjects];
      for (RFBrowserLoginCompletion done in waiting) done(cookies.count ? cookies : nil);
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:login];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:navigation animated:YES completion:nil];
  });
}

#pragma mark - Login request

@interface RFLoginProtocol : NSURLProtocol
@end

static BOOL RFIsLoginRequest(NSURL *url) {
  if (![url.host hasSuffix:@"reddit.com"]) return NO;
  for (NSString *path in @[ @"/auth/v2/login/password", @"/auth/v2/login/sso", @"/auth/v2/login/phone" ])
    if ([url.path isEqualToString:path]) return YES;
  return NO;
}

@implementation RFLoginProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  return RFIsLoginRequest(request.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  NSURLRequest *request = self.request;
  RFAppLog(@"[login] request %@ %@ intercepted", request.HTTPMethod, request.URL.path);
  RFRunBrowserLogin(^(NSArray<NSHTTPCookie *> *cookies) {
    if (!cookies.count) {
      RFAppLog(@"[login] no cookie, request cancelled");
      [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                         code:NSURLErrorCancelled
                                                                     userInfo:nil]];
      return;
    }
    RFUsedAt = [NSDate date];

    // The session cookie goes into the answer, where the app looks for it; the
    // other reddit.com cookies go into the shared cookie storage.
    NSMutableArray<NSString *> *setCookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
      if (![cookie.domain hasSuffix:@"reddit.com"]) continue;
      [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
      if (![cookie.name isEqualToString:RFSessionCookieName]) continue;
      [setCookies addObject:[NSString stringWithFormat:@"%@=%@; Domain=%@; Path=/; Secure; HttpOnly",
                                                       cookie.name, cookie.value, cookie.domain]];
    }

    NSDictionary *headers = @{
      @"Content-Type" : @"application/json",
      @"Set-Cookie" : [setCookies componentsJoinedByString:@", "],
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
    RFAppLog(@"[login] request answered with the web session");
  });
}

- (void)stopLoading {
}

@end

#pragma mark - Install into the app's sessions

// The app builds its own sessions from custom configurations, which don't
// consult classes registered with +registerClass:, so the protocol is added to
// every configuration a session is created with.
static NSURLSessionConfiguration *RFConfigurationWithLogin(NSURLSessionConfiguration *configuration) {
  if (!configuration || [configuration.protocolClasses containsObject:RFLoginProtocol.class]) return configuration;
  NSURLSessionConfiguration *copy = [configuration copy];
  copy.protocolClasses = [@[ RFLoginProtocol.class ] arrayByAddingObjectsFromArray:configuration.protocolClasses ?: @[]];
  return copy;
}

%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
  return %orig(RFConfigurationWithLogin(configuration));
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue {
  return %orig(RFConfigurationWithLogin(configuration), delegate, queue);
}

%end

#pragma mark - Log of the account requests

@interface RFBLTaskObserver : NSObject
@end

@implementation RFBLTaskObserver
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(NSURLSessionTask *)task
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (task.state != NSURLSessionTaskStateCompleted) return;
  @try {
    [task removeObserver:self forKeyPath:@"state"];
  } @catch (__unused NSException *e) {
  }
  NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
  NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? response.statusCode : 0;
  RFAppLog(@"[net] <- %ld %@ err=%@", (long)status, task.originalRequest.URL.path,
           task.error ? [NSString stringWithFormat:@"%@ %ld", task.error.domain, (long)task.error.code] : @"ok");
}
@end

static const void *RFObserverKey = &RFObserverKey;

// Only the account endpoints: method, path and status, never headers or bodies.
static BOOL RFIsAccountRequest(NSURL *url) {
  return [url.host hasSuffix:@"reddit.com"] && [url.path hasPrefix:@"/auth/"];
}

%hook NSURLSessionTask

- (void)resume {
  NSURLRequest *request = self.originalRequest;
  if (request && RFIsAccountRequest(request.URL) && !objc_getAssociatedObject(self, RFObserverKey)) {
    RFAppLog(@"[net] -> %@ %@", request.HTTPMethod, request.URL.path);
    RFBLTaskObserver *observer = [RFBLTaskObserver new];
    objc_setAssociatedObject(self, RFObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addObserver:observer forKeyPath:@"state" options:0 context:NULL];
  }
  %orig;
}

%end

#pragma mark - Sign in with Apple / Google

// Neither can work in a re-signed app: Apple needs an entitlement that
// sideloading drops, and Google's sign-in is refused. Instead of letting them
// fail, the web login opens, where reddit.com offers both. Afterwards the
// login screen finishes the login with the web session.

static void RFAfterSSOLogin(void) {
  RFRunBrowserLogin(^(NSArray<NSHTTPCookie *> *cookies) {
    if (!cookies.count) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Bei Reddit angemeldet"
                         message:@"Tippe jetzt auf „E-Mail oder Benutzername“ und dann auf „Anmelden“. Die Eingaben sind egal."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [RFTopViewController() presentViewController:alert animated:YES completion:nil];
  });
}

%hook ASAuthorizationController

- (void)performRequests {
  BOOL apple = NO;
  for (ASAuthorizationRequest *request in self.authorizationRequests)
    if ([request isKindOfClass:ASAuthorizationAppleIDRequest.class]) apple = YES;
  RFAppLog(@"[sso] ASAuthorizationController performRequests apple=%d", apple);
  if (!apple) {
    %orig;
    return;
  }
  // Tell the app the user cancelled, so its screen is usable again.
  id<ASAuthorizationControllerDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(authorizationController:didCompleteWithError:)])
    [delegate authorizationController:self
                 didCompleteWithError:[NSError errorWithDomain:ASAuthorizationErrorDomain
                                                          code:ASAuthorizationErrorCanceled
                                                      userInfo:nil]];
  RFAfterSSOLogin();
}

%end

%hook ASWebAuthenticationSession

- (BOOL)start {
  NSURL *url = nil;
  for (NSString *key in @[ @"URL", @"_URL", @"initialURL" ]) {
    @try {
      id value = [self valueForKey:key];
      if ([value isKindOfClass:NSURL.class]) {
        url = value;
        break;
      }
    } @catch (__unused NSException *e) {
    }
  }
  RFAppLog(@"[sso] ASWebAuthenticationSession start host=%@ path=%@", url.host, url.path);
  NSString *host = url.host.lowercaseString ?: @"";
  if (![host containsString:@"google"] && ![host containsString:@"apple"]) return %orig;
  [self cancel];
  RFAfterSSOLogin();
  return YES;
}

%end

#pragma mark - Login screen

static BOOL RFIsLoginScreen(UIViewController *controller) {
  NSString *name = NSStringFromClass(controller.class);
  return [name containsString:@"AuthenticationKit"] && [name containsString:@"LoginViewController"];
}

static NSString *const RFHandledKey = @"RFLoginScreenHandled";

static void RFCollectTextFields(UIView *view, NSMutableArray<UITextField *> *fields) {
  if ([view isKindOfClass:UITextField.class]) [fields addObject:(UITextField *)view];
  for (UIView *subview in view.subviews) RFCollectTextFields(subview, fields);
}

static BOOL RFLabelLooksLikeLogin(NSString *label) {
  NSString *lower = label.lowercaseString;
  if (!lower.length) return NO;
  for (NSString *word in @[ @"forgot", @"vergessen", @"sign up", @"registr" ])
    if ([lower containsString:word]) return NO;
  for (NSString *word in @[ @"log in", @"login", @"anmelden", @"einloggen", @"continue", @"weiter" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

// Walks views and accessibility elements (SwiftUI buttons only exist as the latter).
static BOOL RFActivateLoginButton(id node, int depth) {
  if (depth > 40 || !node) return NO;
  BOOL isView = [node isKindOfClass:UIView.class];
  NSString *label = [node respondsToSelector:@selector(accessibilityLabel)] ? [node accessibilityLabel] : nil;
  BOOL isButton = [node respondsToSelector:@selector(accessibilityTraits)] &&
                  ([node accessibilityTraits] & UIAccessibilityTraitButton);
  if (isButton && label.length) {
    RFAppLog(@"[auto] button \"%@\" (%@)", label, [node class]);
    if (RFLabelLooksLikeLogin(label)) {
      if ([node isKindOfClass:UIControl.class]) {
        [(UIControl *)node sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
      }
      if ([node accessibilityActivate]) return YES;
    }
  }
  if (isView)
    for (UIView *subview in [(UIView *)node subviews])
      if (RFActivateLoginButton(subview, depth + 1)) return YES;
  NSInteger count = [node respondsToSelector:@selector(accessibilityElementCount)] ? [node accessibilityElementCount] : 0;
  if (count > 0 && count != NSNotFound && count < 200)
    for (NSInteger i = 0; i < count; i++)
      if (RFActivateLoginButton([node accessibilityElementAtIndex:i], depth + 1)) return YES;
  return NO;
}

// Fills the login form with dummy values and presses its button. Best effort:
// if it doesn't work, tapping "Anmelden" yourself has the same effect.
static void RFAutoSubmit(UIViewController *controller) {
  NSMutableArray<UITextField *> *fields = [NSMutableArray array];
  RFCollectTextFields(controller.view, fields);
  RFAppLog(@"[auto] filling %lu text fields", (unsigned long)fields.count);
  for (UITextField *field in fields) {
    if (field.text.length) continue;
    field.text = field.secureTextEntry ? @"rf-browser-login" : @"rfbrowserlogin";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:field];
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    BOOL pressed = RFActivateLoginButton(controller.view, 0);
    RFAppLog(@"[auto] login button pressed=%d", pressed);
  });
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
  %orig;
  NSString *name = NSStringFromClass(self.class);
  if ([name containsString:@"Authentication"] || [name containsString:@"Login"] || [name containsString:@"Welcome"] ||
      [name containsString:@"Splash"] || [name containsString:@"SSO"] || [name containsString:@"SignUp"] ||
      [name containsString:@"TwoFactor"])
    RFAppLog(@"[screen] %@", name);

  if (!RFIsLoginScreen(self) || objc_getAssociatedObject(self, (__bridge const void *)RFHandledKey)) return;
  // Closing the web view shows this screen again.
  if (RFLoginShown || (RFLoginClosedAt && -[RFLoginClosedAt timeIntervalSinceNow] < 3)) return;
  objc_setAssociatedObject(self, (__bridge const void *)RFHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  __weak UIViewController *weakSelf = self;
  RFRunBrowserLogin(^(NSArray<NSHTTPCookie *> *cookies) {
    UIViewController *controller = weakSelf;
    if (!cookies.count || !controller) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      RFAutoSubmit(controller);
    });
  });
}

%end

%ctor {
  RFAppLogInstall();
  if (getenv("RF_NO_BROWSER_LOGIN")) {
    RFAppLog(@"[boot] browser login switched off");
    return;
  }
  [NSURLProtocol registerClass:RFLoginProtocol.class];
  %init;
  RFAppLog(@"[boot] browser login active");
}
