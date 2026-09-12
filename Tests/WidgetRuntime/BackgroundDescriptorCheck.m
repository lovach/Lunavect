// macOS-only integration check for the experimental WidgetKit descriptor hook.
// clang -fobjc-arc -framework Foundation -IWidget Tests/WidgetRuntime/BackgroundDescriptorCheck.m Widget/WidgetBackground.m -o /tmp/lunavect-background-check
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "WidgetBackground.h"

static id descriptor(Class cls, NSString *kind) {
    return ((id (*)(id, SEL, id, id, id, NSUInteger, id))objc_msgSend)([cls alloc],
        NSSelectorFromString(@"initWithExtensionBundleIdentifier:containerBundleIdentifier:kind:supportedFamilies:intentType:"),
        @"com.weekleft.app.widget", @"com.weekleft.app", kind, 7, nil);
}
static BOOL hasMaterial(id value, BOOL expected) {
    for (NSInteger family = 0; family < 3; family++) {
        for (NSString *name in @[@"isTransparentForFamily:", @"wantsMaterialBackgroundForFamily:"]) {
            if (((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(value, NSSelectorFromString(name), family) != expected) return NO;
        }
    }
    return YES;
}
static int wrongBoolean(id object, SEL selector) { return 7; }
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc > 1 && strcmp(argv[1], "--incompatible") == 0) {
        Class fake = objc_allocateClassPair([NSObject class], "CHSWidgetDescriptor", 0);
        class_addMethod(fake, NSSelectorFromString(@"isTransparent"), (IMP)wrongBoolean, "i@:");
        objc_registerClassPair(fake);
        Method method = class_getInstanceMethod(fake, NSSelectorFromString(@"isTransparent"));
        IMP original = method_getImplementation(method);
        LunavectSetWidgetBackgroundEnabled(YES);
        if (method_getImplementation(method) != original) return 1;
        puts("PASS: incompatible descriptor unchanged"); return 0;
    }
    dlopen("/System/Library/PrivateFrameworks/ChronoServices.framework/ChronoServices", RTLD_NOW);
    Class cls = NSClassFromString(@"CHSWidgetDescriptor");
    if (!cls) return 77;
    SEL initializer = NSSelectorFromString(@"initWithExtensionBundleIdentifier:containerBundleIdentifier:kind:supportedFamilies:intentType:");
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:initializer];
    if (!signature || signature.numberOfArguments != 7 || strcmp(signature.methodReturnType, @encode(id)) != 0) return 77;
    for (NSUInteger index = 2; index < 7; index++) {
        if (strcmp([signature getArgumentTypeAtIndex:index], index == 5 ? @encode(NSUInteger) : @encode(id)) != 0) return 77;
    }
    for (NSString *name in @[@"isTransparentForFamily:", @"wantsMaterialBackgroundForFamily:"]) {
        NSMethodSignature *method = [cls instanceMethodSignatureForSelector:NSSelectorFromString(name)];
        if (!method || method.numberOfArguments != 3 || strcmp(method.methodReturnType, @encode(BOOL)) != 0 ||
            strcmp([method getArgumentTypeAtIndex:2], @encode(NSInteger)) != 0) return 77;
    }
    id own = descriptor(cls, @"WeekleftWidget"), other = descriptor(cls, @"OtherWidget");
    if (!hasMaterial(own, NO) || !hasMaterial(other, NO)) return 1;
    LunavectSetWidgetBackgroundEnabled(NO);
    if (!hasMaterial(own, NO)) return 4;
    LunavectSetWidgetBackgroundEnabled(YES);
    if (!hasMaterial(own, YES) || !hasMaterial(other, NO)) return 2;
    LunavectSetWidgetBackgroundEnabled(NO);
    if (!hasMaterial(own, NO) || !hasMaterial(other, NO)) return 5;
    LunavectSetWidgetBackgroundEnabled(YES);
    for (NSInteger cycle = 0; cycle < 3; cycle++) {
        NSError *error = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:own requiringSecureCoding:YES error:&error];
        own = [NSKeyedUnarchiver unarchivedObjectOfClass:cls fromData:archive error:&error];
        if (!own || error || !hasMaterial(own, YES)) return 3;
    }
    puts("PASS: on/off/on + 3 archived descriptors, other widget unchanged");
    return 0;
}}
