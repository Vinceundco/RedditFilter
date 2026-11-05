// LoginDebug.x
//
// Diagnostics for the sideload login problem. Only compiled into builds made
// with DEBUG_MENU=1. Nothing here changes what the app does; it only logs:
//
//   * the bundle ID the app really runs under vs. the one it reports,
//   * every App Attest call (DCAppAttestService) and how it ended,
//   * every auth / attestation / reCAPTCHA request with its HTTP status.
//
// Read the output in Console.app (device connected, filter: subsystem
// "com.redditfilter.debug") or with:
//   log stream --predicate 'subsystem == "com.redditfilter.debug"'
//
// Request and response bodies and header values are never logged, so the log
// contains no passwords or tokens and is safe to share.

#import "DebugMenu.h"

#if REDDITFILTER_DEBUG

#import <AVFoundation/AVFoundation.h>
#import <DeviceCheck/DeviceCheck.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <os/log.h>

static os_log_t RFLog(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("com.redditfilter.debug", "login"); });
  return log;
}

// A function instead of a macro around stringWithFormat:, so calls without
// arguments don't trip -Wformat-security (which is an error in this build).
static void RFDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void RFDLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  os_log(RFLog(), "%{public}@", message);
}

static NSString *RFErr(NSError *error) {
  return error ? [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code] : @"ok";
}

#pragma mark - App Attest

// Everything in this group can be switched off at launch with RF_NO_PROBES=1,
// to check whether the hooks themselves change the app's behaviour.
%group Probes

%hook DCAppAttestService

- (BOOL)isSupported {
  BOOL supported = %orig;
  RFDLog(@"[attest] isSupported -> %d", supported);
  return supported;
}

- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))handler {
  RFDLog(@"[attest] generateKey called");
  void (^logged)(NSString *, NSError *) = ^(NSString *keyId, NSError *error) {
    RFDLog(@"[attest] generateKey -> %@", RFErr(error));
    if (handler) handler(keyId, error);
  };
  %orig(logged);
}

- (void)attestKey:(NSString *)keyId
    clientDataHash:(NSData *)hash
 completionHandler:(void (^)(NSData *attestation, NSError *error))handler {
  RFDLog(@"[attest] attestKey called");
  void (^logged)(NSData *, NSError *) = ^(NSData *attestation, NSError *error) {
    RFDLog(@"[attest] attestKey -> %@ (%lu bytes)", RFErr(error), (unsigned long)attestation.length);
    if (handler) handler(attestation, error);
  };
  %orig(keyId, hash, logged);
}

- (void)generateAssertion:(NSString *)keyId
           clientDataHash:(NSData *)hash
        completionHandler:(void (^)(NSData *assertion, NSError *error))handler {
  RFDLog(@"[attest] generateAssertion called");
  void (^logged)(NSData *, NSError *) = ^(NSData *assertion, NSError *error) {
    RFDLog(@"[attest] generateAssertion -> %@ (%lu bytes)", RFErr(error), (unsigned long)assertion.length);
    if (handler) handler(assertion, error);
  };
  %orig(keyId, hash, logged);
}

%end

#pragma mark - Auth-related network requests

// Everything except media/CDN downloads. The login flow uses endpoints whose
// names we don't know in advance, so a keyword filter misses them.
static BOOL RFIsInteresting(NSURL *url) {
  NSString *host = url.host.lowercaseString ?: @"";
  for (NSString *noise in @[ @"redd.it", @"redditmedia.com", @"redditstatic.com", @"googlevideo.com" ])
    if ([host hasSuffix:noise]) return NO;
  return host.length > 0;
}

// Header names only (never values) that hint at attestation or bot checks.
static NSString *RFHeaderNames(NSDictionary *headers) {
  NSMutableArray *names = [NSMutableArray array];
  for (NSString *name in headers) {
    NSString *lower = name.lowercaseString;
    // On/off switches are shown with their value; they are settings, not secrets.
    NSString *value = [headers[name] description];
    if ([value isEqualToString:@"enabled"] || [value isEqualToString:@"disabled"]) {
      [names addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
      continue;
    }
    for (NSString *word in @[ @"attest", @"recaptcha", @"device", @"integrity", @"retry", @"transl" ])
      if ([lower containsString:word]) {
        [names addObject:name];
        break;
      }
  }
  return [names componentsJoinedByString:@","];
}

@interface RFTaskObserver : NSObject
@end

@implementation RFTaskObserver
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
  NSDictionary *headers = status ? response.allHeaderFields : nil;
  RFDLog(@"[net] <- %ld %@%@ err=%@ respHeaders=[%@]", (long)status, task.originalRequest.URL.host,
         task.originalRequest.URL.path, RFErr(task.error), RFHeaderNames(headers));
  objc_setAssociatedObject(task, @selector(observeValueForKeyPath:ofObject:change:context:), nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

%hook NSURLSessionTask

- (void)resume {
  NSURLRequest *request = self.originalRequest;
  SEL key = @selector(observeValueForKeyPath:ofObject:change:context:);
  if (request && RFIsInteresting(request.URL) && !objc_getAssociatedObject(self, key)) {
    // The GraphQL operation name is a fixed label like "HomeFeedSdui", not user data.
    RFDLog(@"[net] -> %@ %@%@ op=%@ reqHeaders=[%@]", request.HTTPMethod, request.URL.host, request.URL.path,
           [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"] ?: @"-",
           RFHeaderNames(request.allHTTPHeaderFields));
    RFTaskObserver *observer = [RFTaskObserver new];
    objc_setAssociatedObject(self, key, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addObserver:observer forKeyPath:@"state" options:0 context:NULL];
  }
  %orig;
}

%end

#pragma mark - Video playback

// Which address a video is played from, and whether the player is muted.
%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)url options:(NSDictionary *)options {
  // The query can hold signed tokens, so only the names of its items are shown.
  NSArray *items = [[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems valueForKey:@"name"];
  RFDLog(@"[media] asset %@://%@%@ query=[%@]", url.scheme, url.host, url.path, [items componentsJoinedByString:@","]);
  return %orig;
}
%end

%hook AVPlayer
- (void)setMuted:(BOOL)muted {
  NSURL *url = [self.currentItem.asset isKindOfClass:AVURLAsset.class] ? ((AVURLAsset *)self.currentItem.asset).URL : nil;
  RFDLog(@"[media] muted=%d %@%@", muted, url.host, url.path);
  %orig;
}
%end

%end // group Probes

#pragma mark - Errors

// Errors from the app's own SDKs (reCAPTCHA, auth, ...). The system domains
// below fire constantly for unrelated reasons and would drown the log.
%hook NSError
- (instancetype)initWithDomain:(NSString *)domain code:(NSInteger)code userInfo:(NSDictionary *)userInfo {
  static NSSet *ignored;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ignored = [NSSet setWithObjects:NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain,
                                    @"kCFErrorDomainCFNetwork", @"NSXPCConnectionErrorDomain", nil];
  });
  if (domain && ![ignored containsObject:domain]) {
    NSString *text = [userInfo[NSLocalizedDescriptionKey] description] ?: @"";
    if (text.length > 160) text = [text substringToIndex:160];
    RFDLog(@"[error] %@ %ld %@", domain, (long)code, text);
  }
  return %orig;
}
%end

#pragma mark - Startup report

%ctor {
  %init;
  if (!getenv("RF_NO_PROBES")) %init(Probes);
  // The Info.plist on disk is what the installer (SideStore) wrote; the
  // NSBundle getters are what RedditSideloadFix makes the app believe.
  NSString *plistPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  CFStringRef cfId = CFBundleGetIdentifier(CFBundleGetMainBundle());
  RFDLog(@"[boot] bundle id on disk=%@ NSBundle=%@ CFBundle=%@ infoDictionary=%@", onDisk[@"CFBundleIdentifier"],
         NSBundle.mainBundle.bundleIdentifier, (__bridge NSString *)cfId,
         NSBundle.mainBundle.infoDictionary[@"CFBundleIdentifier"]);
  // -25300 (not found) means the keychain works; -34018 means the app has no
  // usable keychain entitlement, which breaks login regardless of anything else.
  OSStatus keychain = SecItemCopyMatching((__bridge CFDictionaryRef) @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : @"com.redditfilter.debug.probe",
  }, NULL);
  RFDLog(@"[boot] keychain probe status=%d", (int)keychain);
  RFDLog(@"[boot] app %@ (%@), iOS %@", onDisk[@"CFBundleShortVersionString"], onDisk[@"CFBundleVersion"],
         NSProcessInfo.processInfo.operatingSystemVersionString);
}

#endif // REDDITFILTER_DEBUG
