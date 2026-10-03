#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>


// Adding CarPlay scene support opts this legacy app into scene lifecycle.
// Adopt the original app delegate's window so Google's startup UI survives.
@interface YTCPPhoneSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIWindowScene *phoneScene;
@end
@implementation YTCPPhoneSceneDelegate
- (void)adoptOriginalWindow:(NSUInteger)attempt {
    if (!self.phoneScene) return;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    UIWindow *original = [delegate respondsToSelector:@selector(window)] ? delegate.window : nil;
    if (original && original.rootViewController) {
        if (self.window != original) self.window.hidden = YES;
        original.windowScene = self.phoneScene;
        self.window = original;
        [original makeKeyAndVisible];
        NSLog(@"[YouTubeCarPlay] Phone window adopted: %@", original.rootViewController);
        return;
    }
    if (attempt < 60) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self adoptOriginalWindow:attempt + 1]; });
    else NSLog(@"[YouTubeCarPlay] No original delegate window; startup bridge failed");
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.phoneScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:self.phoneScene];
    UIViewController *loading = [UIViewController new];
    loading.view.backgroundColor = UIColor.blackColor;
    UILabel *label = [[UILabel alloc] initWithFrame:self.window.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = @"Starting native YouTube…";
    label.textAlignment = NSTextAlignmentCenter; label.textColor = UIColor.whiteColor;
    [loading.view addSubview:label];
    self.window.rootViewController = loading;
    [self.window makeKeyAndVisible];
    [self adoptOriginalWindow:0];
}
- (void)sceneDidDisconnect:(UIScene *)scene { self.phoneScene = nil; }
@end

// Experimental: transfer the live native controller, never duplicate its view.
// The phone UI is restored when the car scene disconnects.
@interface YTCPSceneDelegate : UIResponder <CPTemplateApplicationSceneDelegate>
@property(nonatomic, strong) UIWindow *carWindow;
@property(nonatomic, strong) UIWindow *phoneWindow;
@property(nonatomic, strong) UIViewController *nativeController;
@property(nonatomic, strong) UIViewController *placeholder;
@end
@implementation YTCPSceneDelegate
- (void)attachNativeInterface:(NSUInteger)attempt {
    if (!self.carWindow || self.nativeController) return;
    UIWindow *phone = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.rootViewController && candidate.windowLevel == UIWindowLevelNormal && (!phone || candidate.isKeyWindow)) phone = candidate;
            }
        }
    }
    if (!phone) {
        // Legacy app windows can exist without a phone scene.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate != self.carWindow && ![candidate isKindOfClass:CPWindow.class] && candidate.rootViewController && candidate.windowLevel == UIWindowLevelNormal) { phone = candidate; break; }
        }
#pragma clang diagnostic pop
    }
    if (!phone) {
        if (attempt < 30) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self attachNativeInterface:attempt + 1]; });
        return;
    }
    self.phoneWindow = phone;
    self.nativeController = phone.rootViewController;
    self.placeholder = [UIViewController new];
    self.placeholder.view.backgroundColor = UIColor.blackColor;
    UILabel *label = [UILabel new];
    label.text = @"YouTube interface moved to the car display.\nDisconnect CarPlay to restore it here.";
    label.textColor = UIColor.whiteColor; label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.placeholder.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.centerYAnchor constraintEqualToAnchor:self.placeholder.view.centerYAnchor], [label.leadingAnchor constraintEqualToAnchor:self.placeholder.view.leadingAnchor constant:24], [label.trailingAnchor constraintEqualToAnchor:self.placeholder.view.trailingAnchor constant:-24]]];
    phone.rootViewController = self.placeholder;
    self.carWindow.rootViewController = self.nativeController;
    [self.carWindow makeKeyAndVisible];
    NSLog(@"[YouTubeCarPlay] Attached native controller %@", self.nativeController);
}
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didConnectInterfaceController:(CPInterfaceController *)controller toWindow:(CPWindow *)window {
    self.carWindow = window;
    [self attachNativeInterface:0];
}
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didConnectInterfaceController:(CPInterfaceController *)controller {
    CPListItem *item = [[CPListItem alloc] initWithText:@"Native interface unavailable" detailText:@"iOS did not provide a drawable CarPlay window."];
    CPListTemplate *list = [[CPListTemplate alloc] initWithTitle:@"YouTube experiment" sections:@[[[CPListSection alloc] initWithItems:@[item]]]];
    [controller setRootTemplate:list animated:NO completion:nil];
    NSLog(@"[YouTubeCarPlay] Template-only connection; cannot host native UI");
}
- (void)restore {
    if (self.nativeController && self.phoneWindow.rootViewController == self.placeholder) {
        self.carWindow.rootViewController = nil;
        self.phoneWindow.rootViewController = self.nativeController;
        [self.phoneWindow makeKeyAndVisible];
    }
    self.nativeController = nil; self.placeholder = nil;
    self.phoneWindow = nil; self.carWindow = nil;
}
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didDisconnectInterfaceController:(CPInterfaceController *)controller fromWindow:(CPWindow *)window { [self restore]; }
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didDisconnectInterfaceController:(CPInterfaceController *)controller { [self restore]; }
- (void)sceneDidDisconnect:(UIScene *)scene { [self restore]; }
@end

#import <objc/runtime.h>
// Preserve Google's phone scene configuration while routing only CarPlay.
static IMP YTCPOriginalConfiguration;
static UISceneConfiguration *YTCPConfiguration(id self, SEL selector, UIApplication *app, UISceneSession *session, UISceneConnectionOptions *options) {
    if ([session.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication]) {
        UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"YouTube CarPlay Experiment" sessionRole:session.role];
        configuration.sceneClass = CPTemplateApplicationScene.class;
        configuration.delegateClass = YTCPSceneDelegate.class;
        NSLog(@"[YouTubeCarPlay] Routing CarPlay scene to injected delegate");
        return configuration;
    }
    if (YTCPOriginalConfiguration) {
        UISceneConfiguration *native = ((UISceneConfiguration *(*)(id,SEL,UIApplication *,UISceneSession *,UISceneConnectionOptions *))YTCPOriginalConfiguration)(self,selector,app,session,options);
        if (native) {
            NSLog(@"[YouTubeCarPlay] Preserving native phone delegate %@", NSStringFromClass(native.delegateClass));
            return native;
        }
    }
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"YouTube Phone" sessionRole:session.role];
    configuration.delegateClass = NSClassFromString(@"YTSceneDelegate") ?: YTCPPhoneSceneDelegate.class;
    return configuration;
}
static IMP YTCPOriginalSetDelegate;
static void YTCPSetDelegate(UIApplication *app, SEL selector, id delegate) {
    if (delegate) {
        Class cls = object_getClass(delegate);
        SEL configurationSelector = @selector(application:configurationForConnectingSceneSession:options:);
        Method method = class_getInstanceMethod(cls, configurationSelector);
        if (!method || method_getImplementation(method) != (IMP)YTCPConfiguration) {
            YTCPOriginalConfiguration = method ? method_getImplementation(method) : NULL;
            const char *types = method ? method_getTypeEncoding(method) : "@@:@@@";
            if (!class_addMethod(cls, configurationSelector, (IMP)YTCPConfiguration, types))
                class_replaceMethod(cls, configurationSelector, (IMP)YTCPConfiguration, types);
            NSLog(@"[YouTubeCarPlay] Installed scene routing for %@", NSStringFromClass(cls));
        }
    }
    ((void (*)(id, SEL, id))YTCPOriginalSetDelegate)(app, selector, delegate);
}
@interface YTCPBootstrap : NSObject @end
@implementation YTCPBootstrap
+ (void)load {
    Method method = class_getInstanceMethod(UIApplication.class, @selector(setDelegate:));
    YTCPOriginalSetDelegate = method_getImplementation(method);
    method_setImplementation(method, (IMP)YTCPSetDelegate);
}
@end
