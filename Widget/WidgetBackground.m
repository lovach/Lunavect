#import "WidgetBackground.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <stdatomic.h>
#import <string.h>

// Extension-local experiment. Disabled and unsupported paths use original IMPs.
static atomic_bool backgroundEnabled = false;
static void (*originalEncode)(id, SEL, NSCoder *);
static BOOL (*originalTransparent)(id, SEL);
static BOOL (*originalTransparentForFamily)(id, SEL, NSInteger);
static BOOL (*originalMaterialForFamily)(id, SEL, NSInteger);

static BOOL matches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger index = 0; valid && index < arguments.count; index++) {
        type = method_copyArgumentType(method, (unsigned)index + 2);
        valid = type && strcmp(type, arguments[index].UTF8String) == 0;
        free(type);
    }
    return valid;
}
static BOOL isLunavectDescriptor(id descriptor) {
    if (!atomic_load(&backgroundEnabled)) return NO;
    SEL kind = NSSelectorFromString(@"kind");
    if (!matches([descriptor class], kind, @encode(id), @[])) return NO;
    id value = ((id (*)(id, SEL))objc_msgSend)(descriptor, kind);
    return [value isEqual:@"WeekleftWidget"] || [value isEqual:@"LunavectActivityWidget"] || [value isEqual:@"LunavectOverviewWidget"];
}
static BOOL transparent(id object, SEL selector) {
    return isLunavectDescriptor(object) ? YES : originalTransparent(object, selector);
}
static BOOL transparentForFamily(id object, SEL selector, NSInteger family) {
    return isLunavectDescriptor(object) ? YES : originalTransparentForFamily(object, selector, family);
}
static BOOL materialForFamily(id object, SEL selector, NSInteger family) {
    return isLunavectDescriptor(object) ? YES : originalMaterialForFamily(object, selector, family);
}
static void encodeWithDesktopMaterial(id descriptor, SEL selector, NSCoder *coder) {
    id output = descriptor;
    @try {
        if (isLunavectDescriptor(descriptor) && matches([descriptor class], @selector(mutableCopy), @encode(id), @[])) {
            id candidate = [descriptor mutableCopy];
            SEL transparent = NSSelectorFromString(@"setTransparent:");
            SEL background = NSSelectorFromString(@"setPreferredBackgroundStyle:");
            SEL removable = NSSelectorFromString(@"setBackgroundRemovable:");
            Class cls = [candidate class];
            if (matches(cls, transparent, @encode(void), @[@(@encode(BOOL))]) &&
                matches(cls, background, @encode(void), @[@(@encode(NSUInteger))]) &&
                matches(cls, removable, @encode(void), @[@(@encode(BOOL))])) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(candidate, transparent, YES);
                ((void (*)(id, SEL, BOOL))objc_msgSend)(candidate, removable, YES);
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(candidate, background, 2);
                output = candidate;
            }
        }
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "Lunavect widget: background compatibility fallback");
    }
    originalEncode(output, selector, coder);
}
void LunavectSetWidgetBackgroundEnabled(BOOL enabled) {
    if (!enabled) { atomic_store(&backgroundEnabled, false); return; }
    Class descriptor = NSClassFromString(@"CHSWidgetDescriptor");
    SEL encode = @selector(encodeWithCoder:), plain = NSSelectorFromString(@"isTransparent");
    SEL family = NSSelectorFromString(@"isTransparentForFamily:"), material = NSSelectorFromString(@"wantsMaterialBackgroundForFamily:");
    // Preflight every method before replacing any implementation. A changed ABI
    // disables the experiment rather than calling a method with the wrong types.
    if (!matches(descriptor, encode, @encode(void), @[@(@encode(id))]) ||
        !matches(descriptor, NSSelectorFromString(@"kind"), @encode(id), @[]) ||
        !matches(descriptor, plain, @encode(BOOL), @[]) ||
        !matches(descriptor, family, @encode(BOOL), @[@(@encode(NSInteger))]) ||
        !matches(descriptor, material, @encode(BOOL), @[@(@encode(NSInteger))])) {
        atomic_store(&backgroundEnabled, false);
        os_log_error(OS_LOG_DEFAULT, "Lunavect widget: unsupported descriptor ABI; using standard background");
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        originalEncode = (void *)method_setImplementation(class_getInstanceMethod(descriptor, encode), (IMP)encodeWithDesktopMaterial);
        originalTransparent = (void *)method_setImplementation(class_getInstanceMethod(descriptor, plain), (IMP)transparent);
        originalTransparentForFamily = (void *)method_setImplementation(class_getInstanceMethod(descriptor, family), (IMP)transparentForFamily);
        originalMaterialForFamily = (void *)method_setImplementation(class_getInstanceMethod(descriptor, material), (IMP)materialForFamily);
    });
    atomic_store(&backgroundEnabled, true);
}
