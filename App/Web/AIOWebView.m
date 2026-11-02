#import "AIOWebView.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/*
 * Follows the WKWebView wrapper of the working aiostreams-tvos project: WebKit
 * loaded with dlopen, the page focused through its content view, and the
 * whole screen given to the page to lay out in. Added here: a URL scheme that
 * serves the bundled web app, and a policy for links that leave it.
 */

static NSString *const kHandlerName = @"aiostreamsNative";

static void AIOLoadWebKit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"WKWebView") != Nil) return;
        NSArray<NSString *> *paths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];
        for (NSString *path in paths) {
            if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) break;
        }
    });
}

static id AIOSend0(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static void AIOSendVoid(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(target, sel);
}

static void AIOSendObject(id target, NSString *selectorName, id value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, value);
}

static void AIOSendBool(id target, NSString *selectorName, BOOL value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
}

static NSString *AIOMimeType(NSString *extension) {
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = @{
            @"html": @"text/html; charset=utf-8", @"js": @"text/javascript; charset=utf-8",
            @"mjs": @"text/javascript; charset=utf-8", @"css": @"text/css; charset=utf-8",
            @"json": @"application/json", @"map": @"application/json", @"svg": @"image/svg+xml",
            @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"webp": @"image/webp",
            @"avif": @"image/avif", @"gif": @"image/gif", @"ico": @"image/x-icon", @"woff": @"font/woff",
            @"woff2": @"font/woff2", @"ttf": @"font/ttf", @"wasm": @"application/wasm",
            @"txt": @"text/plain; charset=utf-8", @"webmanifest": @"application/manifest+json",
        };
    });
    return types[extension.lowercaseString] ?: @"application/octet-stream";
}

#pragma mark - Delegate

/**
 * Takes WebKit's delegate calls and serves the app's scheme. The user content
 * controller keeps it strongly, so it holds the view weakly.
 */
@interface AIOWebKitDelegate : NSObject
@property (nonatomic, weak) AIOWebView *owner;
@property (nonatomic, copy) NSString *scheme;
@property (nonatomic, strong) NSURL *root;
@end

@interface AIOWebView ()
@property (nonatomic, strong, nullable) id webView;
@property (nonatomic, strong, nullable) id contentController;
@property (nonatomic, strong) AIOWebKitDelegate *delegate;
@property (nonatomic, strong, nullable) NSURL *lastURL;
- (void)receiveBody:(id)body;
- (void)navigationFinished;
- (void)navigationFailed:(NSError *)error;
- (void)contentProcessEnded;
- (void)openURL:(NSURL *)url;
- (void)served:(NSString *)path status:(NSInteger)status bytes:(NSUInteger)bytes;
@end

@implementation AIOWebKitDelegate

+ (void)initialize {
    if (self != [AIOWebKitDelegate class]) return;
    AIOLoadWebKit();
    // WebKit checks some delegates for these at runtime.
    for (NSString *name in @[@"WKScriptMessageHandler", @"WKNavigationDelegate", @"WKUIDelegate", @"WKURLSchemeHandler"]) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (protocol) class_addProtocol(self, protocol);
    }
}

- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    [self.owner receiveBody:AIOSend0(message, @"body")];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.owner navigationFinished];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.owner contentProcessEnded];
}

/** The app's pages and what they embed load; a link anywhere else goes to the system. */
- (void)webView:(id)webView
    decidePolicyForNavigationAction:(id)action
                    decisionHandler:(void (^)(NSInteger))decisionHandler {
    NSURLRequest *request = AIOSend0(action, @"request");
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    id frame = AIOSend0(action, @"targetFrame");
    BOOL mainFrame = frame && ((BOOL (*)(id, SEL))objc_msgSend)(frame, NSSelectorFromString(@"isMainFrame"));
    BOOL ours = [scheme isEqualToString:self.scheme] ||
                [@[@"about", @"data", @"blob"] containsObject:scheme];
    // Frames such as trailers load; the page itself never leaves, as a TV has no browser.
    BOOL embedded = !mainFrame && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
    if (ours || embedded) {
        decisionHandler(1);  // WKNavigationActionPolicyAllow
        return;
    }
    decisionHandler(0);  // WKNavigationActionPolicyCancel
    if (url) [self.owner openURL:url];
}

- (void)webView:(id)webView startURLSchemeTask:(id)task {
    NSURLRequest *request = AIOSend0(task, @"request");
    NSURL *url = request.URL;
    NSString *path = url.path.length > 1 ? url.path : @"/index.html";
    NSString *rootPath = self.root.URLByStandardizingPath.path;
    NSURL *file = [self.root URLByAppendingPathComponent:[path substringFromIndex:1]].URLByStandardizingPath;
    NSData *data = nil;
    if ([path hasPrefix:@"/thumbnail/"]) {
        // Seek-bar thumbnails the player made, which the page was sent the paths of.
        AIOWebView *owner = self.owner;
        if (owner.thumbnailAtPath) data = owner.thumbnailAtPath(path);
    } else if ([file.path hasPrefix:[rootPath stringByAppendingString:@"/"]]) {
        // Nothing outside the bundled build.
        data = [NSData dataWithContentsOfURL:file];
    }
    NSInteger status = data ? 200 : 404;
    data = data ?: [NSData data];
    NSDictionary *headers = @{
        @"Content-Type": data.length ? AIOMimeType(path.pathExtension) : @"text/plain",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
        @"Cache-Control": @"no-cache",
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    AIOSendObject(task, @"didReceiveResponse:", response);
    AIOSendObject(task, @"didReceiveData:", data);
    AIOSendVoid(task, @"didFinish");
    [self.owner served:path status:status bytes:data.length];
}

- (void)webView:(id)webView stopURLSchemeTask:(id)task {
    // Each file is answered in full as it is asked for, so nothing is left to stop.
}

@end

#pragma mark - View

@implementation AIOWebView

- (instancetype)initWithFrame:(CGRect)frame scheme:(NSString *)scheme root:(NSURL *)root {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    _delegate = [AIOWebKitDelegate new];
    _delegate.owner = self;
    _delegate.scheme = scheme.lowercaseString;
    _delegate.root = root;
    [self build];
    return self;
}

- (BOOL)available {
    return self.webView != nil;
}

- (void)build {
    AIOLoadWebKit();
    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    Class controllerClass = NSClassFromString(@"WKUserContentController");
    if (!configurationClass || !webViewClass || !controllerClass) return;

    id configuration = [configurationClass new];
    id controller = [controllerClass new];
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([controller respondsToSelector:addHandler]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, self.delegate, kHandlerName);
    }
    AIOSendObject(configuration, @"setUserContentController:", controller);
    self.contentController = controller;

    SEL setScheme = NSSelectorFromString(@"setURLSchemeHandler:forURLScheme:");
    if ([configuration respondsToSelector:setScheme]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(configuration, setScheme, self.delegate, self.delegate.scheme);
    }
    AIOSendBool(configuration, @"setAllowsInlineMediaPlayback:", YES);
    AIOSendBool(configuration, @"setMediaPlaybackRequiresUserAction:", NO);
    SEL mediaTypes = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([configuration respondsToSelector:mediaTypes]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypes, 0);
    }

    id webView = ((id (*)(id, SEL))objc_msgSend)(webViewClass, @selector(alloc));
    SEL init = NSSelectorFromString(@"initWithFrame:configuration:");
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webView, init, self.bounds, configuration);
    if (!webView) return;

    UIView *view = (UIView *)webView;
    view.frame = self.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The player is drawn beneath, so the page must be see-through.
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    UIScrollView *scrollView = AIOSend0(webView, @"scrollView");
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.opaque = NO;
    // The page lays itself out to the screen and scrolls itself.
    scrollView.scrollEnabled = NO;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    AIOSendObject(webView, @"setUnderPageBackgroundColor:", UIColor.clearColor);
    AIOSendObject(webView, @"setNavigationDelegate:", self.delegate);
    AIOSendObject(webView, @"setUIDelegate:", self.delegate);
    // Lets Safari on a Mac inspect the page, for debugging.
    AIOSendBool(webView, @"setInspectable:", YES);
    AIOSendObject(webView, @"setApplicationNameForUserAgent:", @"AIOStreamsTV");

    [self addSubview:view];
    self.webView = webView;
}

- (void)setStartScript:(NSString *)script {
    id controller = self.contentController;
    Class scriptClass = NSClassFromString(@"WKUserScript");
    if (!controller || !scriptClass) return;
    AIOSendVoid(controller, @"removeAllUserScripts");
    // At document start, in the main frame only, before the page's own scripts.
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (![scriptClass instancesRespondToSelector:scriptInit]) return;
    id userScript = ((id (*)(id, SEL))objc_msgSend)(scriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, scriptInit, script, 0, YES);
    AIOSendObject(controller, @"addUserScript:", userScript);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.webView).frame = self.bounds;
    [self fillScreen];
}

/**
 * WebKit fits the page to the screen less tvOS's safe area (the margin kept
 * for TVs that overscan) but draws it from the left edge, leaving a strip on
 * the right. The page keeps its own margins, so the web view gets the whole
 * screen to lay out in.
 */
- (void)fillScreen {
    id webView = self.webView;
    if (!webView) return;
    CGSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    SEL unobscured = NSSelectorFromString(@"_setUnobscuredSafeAreaInsets:");
    if ([webView respondsToSelector:unobscured]) {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(webView, unobscured, UIEdgeInsetsZero);
    }
    SEL obscured = NSSelectorFromString(@"_setObscuredInsets:");
    if ([webView respondsToSelector:obscured]) {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(webView, obscured, UIEdgeInsetsZero);
    }
    SEL layout = NSSelectorFromString(@"_overrideLayoutParametersWithMinimumLayoutSize:maximumUnobscuredSizeOverride:");
    if ([webView respondsToSelector:layout]) {
        ((void (*)(id, SEL, CGSize, CGSize))objc_msgSend)(webView, layout, size, size);
    }
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    AIOSendObject(self.webView, @"setCustomUserAgent:", _userAgent);
}

- (void)loadURL:(NSURL *)url {
    self.lastURL = url;
    AIOSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
}

- (void)evaluateJavaScript:(NSString *)script {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (!self.webView || ![self.webView respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, script, nil);
}

- (void)focusPage {
    UIView *view = (UIView *)self.webView;
    if (!view) return;
    // WebKit counts the page focused while its content view is first responder.
    UIView *content = [self contentViewIn:view];
    if (![content becomeFirstResponder]) [view becomeFirstResponder];
}

- (nullable UIView *)contentViewIn:(UIView *)view {
    if ([NSStringFromClass(view.class) hasPrefix:@"WKContentView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = [self contentViewIn:subview];
        if (found) return found;
    }
    return nil;
}

- (void)removeAllWebData:(void (^)(void))done {
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    id store = AIOSend0(storeClass, @"defaultDataStore");
    id types = AIOSend0(storeClass, @"allWebsiteDataTypes");
    SEL remove = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (!store || !types || ![store respondsToSelector:remove]) {
        done();
        return;
    }
    void (^finished)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), done);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, remove, types, NSDate.distantPast, finished);
}

#pragma mark Delegate calls

- (void)receiveBody:(id)body {
    if (![body isKindOfClass:NSString.class] || !self.onMessage) return;
    NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:NSDictionary.class]) self.onMessage(json);
}

- (void)navigationFinished {
    if (self.onLoadFinished) self.onLoadFinished();
}

- (void)navigationFailed:(NSError *)error {
    // A navigation the page replaced with another is not a failure.
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    // Nor is a link the app handed to the system ("frame load interrupted").
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    if (self.onLoadFailed) self.onLoadFailed(error.localizedDescription ?: @"The page could not load.");
}

- (void)contentProcessEnded {
    // Where the page was, rather than its start.
    NSURL *current = AIOSend0(self.webView, @"URL");
    NSURL *url = current ?: self.lastURL;
    if (url) AIOSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
    if (self.onProcessEnded) self.onProcessEnded();
}

- (void)openURL:(NSURL *)url {
    if (self.onOpenURL) self.onOpenURL(url);
}

- (void)served:(NSString *)path status:(NSInteger)status bytes:(NSUInteger)bytes {
    if (self.onServed) self.onServed(path, status, bytes);
}

@end
