#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <dlfcn.h>

int TBSystemStatus(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!lib) return -1;
    int (*status)(void) = dlsym(lib, "DFRGetStatus");
    return status ? status() : -1;
}

bool TBSupported(void) {
    return [NSTouchBar respondsToSelector:NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:")] ||
           [NSTouchBar respondsToSelector:NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")];
}
bool TBShow(NSTouchBar *bar) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (lib) {
        void (*closeBox)(bool) = dlsym(lib, "DFRSystemModalShowsCloseBoxWhenFrontMost");
        if (closeBox) closeBox(true);
    }
    SEL selector = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    if ([NSTouchBar respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, long long, id))objc_msgSend)(NSTouchBar.class, selector, bar, 1, nil);
        return true;
    }
    selector = NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
    if ([NSTouchBar respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(NSTouchBar.class, selector, bar, nil);
        return true;
    }
    return false;
}
void TBHide(NSTouchBar *bar) {
    SEL selector = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([NSTouchBar respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(NSTouchBar.class, selector, bar);
}
