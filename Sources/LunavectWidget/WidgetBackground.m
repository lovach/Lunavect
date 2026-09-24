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
static void encodeWithTransparentBackground(id descriptor, SEL selector, NSCoder *coder) {
    id output = descriptor;
    @try {
        if (isLunavectDescriptor(descriptor) && matches([descriptor class], @selector(mutableCopy), @encode(id), @[])) {
            id candidate = [descriptor mutableCopy];
            SEL transparent = NSSelectorFromString(@"setTransparent:");
            SEL background = NSSelectorFromString(@"setPreferredBackgroundStyle:");
            SEL removable = NSSelectorFromString(@"setBackgroundRemovable:");
            Class cls = [candidate class];
            if (matches(cls, transparent, @encode(void), @[@(@encode(BOOL))]) &&
                matches(cls, background, @encode(void), @[@(@encode(NSInteger))]) &&
                matches(cls, removable, @encode(void), @[@(@encode(BOOL))])) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(candidate, transparent, YES);
                ((void (*)(id, SEL, BOOL))objc_msgSend)(candidate, removable, YES);
                // Style 2 asks the host for the native blurred material under
                // our adjustable tint, matching system widgets. Validate using
                // original getters: the host never executes our local hooks.
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(candidate, background, 2);
                BOOL supported = originalTransparent(candidate, NSSelectorFromString(@"isTransparent"));
                for (NSInteger family = 0; supported && family < 3; family++) {
                    supported = originalTransparentForFamily(candidate, NSSelectorFromString(@"isTransparentForFamily:"), family)
                        && originalMaterialForFamily(candidate, NSSelectorFromString(@"wantsMaterialBackgroundForFamily:"), family);
                }
                if (supported) output = candidate;
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
        // WidgetKit can encode or query a descriptor on another thread while this
        // runs. A replacement may be called as soon as it is installed and always
        // calls the saved originals, so save all of them before installing any.
        Method encodeMethod = class_getInstanceMethod(descriptor, encode), plainMethod = class_getInstanceMethod(descriptor, plain);
        Method familyMethod = class_getInstanceMethod(descriptor, family), materialMethod = class_getInstanceMethod(descriptor, material);
        originalEncode = (void *)method_getImplementation(encodeMethod);
        originalTransparent = (void *)method_getImplementation(plainMethod);
        originalTransparentForFamily = (void *)method_getImplementation(familyMethod);
        originalMaterialForFamily = (void *)method_getImplementation(materialMethod);
        method_setImplementation(encodeMethod, (IMP)encodeWithTransparentBackground);
        method_setImplementation(plainMethod, (IMP)transparent);
        method_setImplementation(familyMethod, (IMP)transparentForFamily);
        method_setImplementation(materialMethod, (IMP)materialForFamily);
    });
    atomic_store(&backgroundEnabled, true);
}
