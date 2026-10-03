#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <objc/runtime.h>

static void Trace(NSString *format, ...) {
    va_list args;va_start(args,format);NSString *line=[[NSString alloc] initWithFormat:format arguments:args];va_end(args);
    FILE *file=fopen([[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/NativeBridge.log"] fileSystemRepresentation],"a");
    if(file){fprintf(file,"%s\n",line.UTF8String);fclose(file);}
}
static UIViewController *Notice(NSString *message) {
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.blackColor;
    UILabel *label=[UILabel new];label.text=message;label.numberOfLines=0;label.textColor=UIColor.whiteColor;label.textAlignment=NSTextAlignmentCenter;label.translatesAutoresizingMaskIntoConstraints=NO;
    [vc.view addSubview:label];[NSLayoutConstraint activateConstraints:@[[label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],[label.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:24],[label.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-24]]];return vc;
}
@interface NativeSurfaceBridge : NSObject
@property(nonatomic,strong) UIWindow *car;
@property(nonatomic,strong) UIWindow *phone;
@property(nonatomic,strong) UIViewController *native;
@property(nonatomic,strong) UIViewController *placeholder;
@end
@implementation NativeSurfaceBridge
+ (instancetype)shared {static NativeSurfaceBridge *bridge;static dispatch_once_t once;dispatch_once(&once,^{bridge=[self new];});return bridge;}
- (void)attach:(UIWindow *)window attempt:(NSUInteger)attempt {
    if(self.native || !window.windowScene) return;
    self.car=window;
    UIWindow *phone=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if([scene isKindOfClass:UIWindowScene.class] && [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            for(UIWindow *candidate in ((UIWindowScene *)scene).windows)
                if(candidate.rootViewController && candidate.windowLevel==UIWindowLevelNormal && (!phone || candidate.isKeyWindow)) phone=candidate;
        }
    }
    if(!phone) {
        id<UIApplicationDelegate> delegate=UIApplication.sharedApplication.delegate;
        if([delegate respondsToSelector:@selector(window)] && delegate.window.rootViewController)phone=delegate.window;
    }
    if(!phone.rootViewController) {
        Trace(@"Waiting for native phone controller, attempt %lu",(unsigned long)attempt);
        if(attempt<40)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{if(self.car==window)[self attach:window attempt:attempt+1];});
        else window.rootViewController=Notice(@"YouTube's native phone controller is unavailable. Open YouTube on the phone first.");
        return;
    }
    self.phone=phone;self.native=phone.rootViewController;
    self.placeholder=Notice(@"YouTube is on the car display. Disconnect to restore this phone interface.");
    phone.rootViewController=self.placeholder;
    window.rootViewController=self.native;
    [window makeKeyAndVisible];
    Trace(@"Native %@ attached to %@, size %@",NSStringFromClass(self.native.class),window.windowScene.session.role,NSStringFromCGSize(window.bounds.size));
}
- (void)detach:(UIWindow *)window {
    if(self.car!=window)return;
    if(self.native && self.phone.rootViewController==self.placeholder){window.rootViewController=nil;self.phone.rootViewController=self.native;[self.phone makeKeyAndVisible];}
    self.native=nil;self.phone=nil;self.car=nil;self.placeholder=nil;
}
@end

// Same plain-window role handling as CarTV; no CarTV UI or services are loaded.
@interface NativeCarWindowScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation NativeCarWindowScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    Trace(@"Plain window scene connected: %@",session.role);
    if(![scene isKindOfClass:UIWindowScene.class])return;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=Notice(@"Connecting native YouTube…");[self.window makeKeyAndVisible];
    [[NativeSurfaceBridge shared] attach:self.window attempt:0];
}
- (void)sceneDidDisconnect:(UIScene *)scene {[[NativeSurfaceBridge shared] detach:self.window];self.window=nil;}
@end
@interface NativeTemplateScene : UIResponder <CPTemplateApplicationSceneDelegate>
@property(nonatomic,strong) CPWindow *window;
@end
@implementation NativeTemplateScene
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didConnectInterfaceController:(CPInterfaceController *)controller toWindow:(CPWindow *)window {
    Trace(@"Template connection supplied a window");self.window=window;[[NativeSurfaceBridge shared] attach:window attempt:0];
    [controller setRootTemplate:[[CPListTemplate alloc] initWithTitle:@"YouTube Fresh" sections:@[]] animated:NO completion:nil];
}
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didConnectInterfaceController:(CPInterfaceController *)controller {
    Trace(@"Template-only connection");
    CPListItem *item=[[CPListItem alloc] initWithText:@"Native YouTube bridge" detailText:@"Waiting for the separate car window scene."];
    [controller setRootTemplate:[[CPListTemplate alloc] initWithTitle:@"YouTube Fresh" sections:@[[[CPListSection alloc] initWithItems:@[item]]]] animated:NO completion:nil];
}
- (void)templateApplicationScene:(CPTemplateApplicationScene *)scene didDisconnectInterfaceController:(CPInterfaceController *)controller fromWindow:(CPWindow *)window {[[NativeSurfaceBridge shared] detach:self.window];self.window=nil;}
@end
static IMP OriginalSetDelegate, OriginalConfiguration, OriginalResponds;
static BOOL Responds(id self,SEL cmd,SEL selector){if(selector==@selector(application:configurationForConnectingSceneSession:options:))return YES;return ((BOOL(*)(id,SEL,SEL))OriginalResponds)(self,cmd,selector);}
static UISceneConfiguration *Configure(id self,SEL cmd,UIApplication *app,UISceneSession *session,UISceneConnectionOptions *options) {
    Trace(@"Scene requested: %@",session.role);
    if([session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        if(OriginalConfiguration){UISceneConfiguration *original=((id(*)(id,SEL,id,id,id))OriginalConfiguration)(self,cmd,app,session,options);if(original.delegateClass){Trace(@"Preserving native phone delegate %@",NSStringFromClass(original.delegateClass));return original;}}
        UISceneConfiguration *phone=[[UISceneConfiguration alloc] initWithName:@"Native YouTube Phone" sessionRole:session.role];
        phone.sceneClass=UIWindowScene.class;phone.delegateClass=NSClassFromString(@"YTSceneDelegate");Trace(@"Using YouTube's own phone scene delegate %@",NSStringFromClass(phone.delegateClass));return phone;
    }
    BOOL template=[session.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication];
    UISceneConfiguration *configuration=[[UISceneConfiguration alloc] initWithName:template?@"Native YouTube Templates":@"Native YouTube Car Window" sessionRole:session.role];
    configuration.sceneClass=template?CPTemplateApplicationScene.class:UIWindowScene.class;
    configuration.delegateClass=template?NativeTemplateScene.class:NativeCarWindowScene.class;return configuration;
}
static void SetDelegate(UIApplication *app,SEL cmd,id delegate){
    if(delegate){Class cls=object_getClass(delegate);SEL selector=@selector(application:configurationForConnectingSceneSession:options:);Method method=class_getInstanceMethod(cls,selector);
        if(!method || method_getImplementation(method)!=(IMP)Configure){OriginalConfiguration=method?method_getImplementation(method):NULL;class_replaceMethod(cls,selector,(IMP)Configure,method?method_getTypeEncoding(method):"@@:@@@");
            Method responds=class_getInstanceMethod(cls,@selector(respondsToSelector:));OriginalResponds=method_getImplementation(responds);class_replaceMethod(cls,@selector(respondsToSelector:),(IMP)Responds,method_getTypeEncoding(responds));}
    }
    ((void(*)(id,SEL,id))OriginalSetDelegate)(app,cmd,delegate);
}
@interface NativeBootstrap : NSObject @end
@implementation NativeBootstrap
+ (void)load {Method method=class_getInstanceMethod(UIApplication.class,@selector(setDelegate:));OriginalSetDelegate=method_getImplementation(method);method_setImplementation(method,(IMP)SetDelegate);}
@end
