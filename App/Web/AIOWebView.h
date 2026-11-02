#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A WKWebView made at runtime. tvOS ships WebKit but leaves it out of the SDK,
 * so every call goes through the Objective-C runtime. Fine for a sideloaded
 * app; the App Store would refuse it.
 *
 * The page comes from `scheme://localhost/`, served from `root` in the app.
 */
@interface AIOWebView : UIView

/** False when this tvOS has no WebKit to load. */
@property (nonatomic, readonly) BOOL available;
/** A message the page posted to `aiostreamsNative`, parsed from JSON. */
@property (nonatomic, copy, nullable) void (^onMessage)(NSDictionary<NSString *, id> *message);
@property (nonatomic, copy, nullable) void (^onLoadFinished)(void);
@property (nonatomic, copy, nullable) void (^onLoadFailed)(NSString *error);
/** The page's process ended (most often for memory) and the page is loading again where it was. */
@property (nonatomic, copy, nullable) void (^onProcessEnded)(void);
/** A link to anywhere but the app's own pages, such as an external player's. */
@property (nonatomic, copy, nullable) void (^onOpenURL)(NSURL *url);
/** A file the app served, or failed to. */
@property (nonatomic, copy, nullable) void (^onServed)(NSString *path, NSInteger status, NSUInteger bytes);
/** The JPEG the app serves at a `/thumbnail/` path, or nil; called on the main thread. */
@property (nonatomic, copy, nullable) NSData *_Nullable (^thumbnailAtPath)(NSString *path);
/** In place of WebKit's own user agent. */
@property (nonatomic, copy, nullable) NSString *userAgent;

- (instancetype)initWithFrame:(CGRect)frame scheme:(NSString *)scheme root:(NSURL *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/** Replaces the script run at document start, in the main frame, before the page's own. */
- (void)setStartScript:(NSString *)script;
- (void)loadURL:(NSURL *)url;
- (void)evaluateJavaScript:(NSString *)script;
/** As `evaluateJavaScript:`, with `done` called on the main thread once the page has run it. */
- (void)evaluateJavaScript:(NSString *)script done:(void (^)(void))done;
/** Makes the page focused and active, which `:focus` and `:focus-visible` need. */
- (void)focusPage;
/** Forgets everything WebKit saved for pages: storage, IndexedDB, caches. */
- (void)removeAllWebData:(void (^)(void))done;

@end

NS_ASSUME_NONNULL_END
