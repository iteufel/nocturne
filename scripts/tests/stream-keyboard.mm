#import <Foundation/Foundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdio>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>
#include "core/backend.hpp"
#include "protocol.inc"

// Compile the real UIKit-independent character translator used by StreamView.
using UIKeyModifierFlags = NSUInteger;
enum : NSUInteger {
    UIKeyModifierAlphaShift = 1 << 16, UIKeyModifierShift = 1 << 17,
    UIKeyModifierControl = 1 << 18, UIKeyModifierAlternate = 1 << 19,
    UIKeyModifierCommand = 1 << 20, UIKeyModifierNumericPad = 1 << 21
};
struct KeyEvent { u_short keycode; u_short modifierKeycode; u_char modifier; };
@interface KeyboardSupport : NSObject
+ (struct KeyEvent)translateKeyEvent:(unichar)c withModifierFlags:(UIKeyModifierFlags)flags;
+ (void)addShiftModifier:(struct KeyEvent *)event;
+ (void)addControlModifier:(struct KeyEvent *)event;
+ (void)addMetaModifier:(struct KeyEvent *)event;
+ (void)addAltModifier:(struct KeyEvent *)event;
@end
@implementation KeyboardSupport
#include "client.inc"
@end

// Replace only posting and the active-layout query. Apple supplies the real
// layout data; the fixture never selects a system layout or sends a keystroke.
static std::vector<CGEventRef> posted;
static TISInputSourceRef fixtureLayout;
static unsigned layoutQueries;
static void recordPost(CGEventTapLocation, CGEventRef event) {
    posted.push_back(CGEventCreateCopy(event));
}
static TISInputSourceRef currentLayout() {
    layoutQueries++;
    if (fixtureLayout) CFRetain(fixtureLayout);
    return fixtureLayout;
}
#define CGEventPost recordPost
#define TISCopyCurrentKeyboardLayoutInputSource currentLayout
#if __has_include("KeyboardLayout.h")
#include "KeyboardLayout.h"
#endif

namespace lvh::detail::macos {
struct MacosInputState {
    CGEventSourceRef keyboard_source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventFlags keyboard_flags = 0;
    std::mutex keyboard_mutex;
    ~MacosInputState() { if (keyboard_source) CFRelease(keyboard_source); }
};
#include "backend.inc"
}
#include "adapter.inc"

static int failures;
static void check(bool pass, const char *message) {
    printf("%s: %s\n", pass ? "PASS" : "FAIL", message);
    failures += !pass;
}
static void clearEvents() {
    for (auto event : posted) CFRelease(event);
    posted.clear();
}
static TISInputSourceRef layout(CFStringRef identifier) {
    const void *keys[] = { kTISPropertyInputSourceID };
    const void *values[] = { identifier };
    auto properties = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    auto sources = TISCreateInputSourceList(properties, true);
    CFRelease(properties);
    if (!sources || CFArrayGetCount(sources) != 1) std::abort();
    auto result = static_cast<TISInputSourceRef>(const_cast<void *>(CFArrayGetValueAtIndex(sources, 0)));
    CFRetain(result);
    CFRelease(sources);
    return result;
}
static NSString *nativeCharacters(CGEventRef event) {
    auto data = static_cast<CFDataRef>(TISGetInputSourceProperty(fixtureLayout, kTISPropertyUnicodeKeyLayoutData));
    auto keyboard = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
    auto flags = CGEventGetFlags(event);
    UInt32 modifiers = 0;
    if (flags & kCGEventFlagMaskShift) modifiers |= shiftKey;
    if (flags & kCGEventFlagMaskAlternate) modifiers |= optionKey;
    if (flags & kCGEventFlagMaskAlphaShift) modifiers |= alphaLock;
    UniChar buffer[16]{}; UniCharCount count = 0; UInt32 dead = 0;
    auto result = UCKeyTranslate(keyboard, static_cast<UInt16>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode)),
        kUCKeyActionDown, modifiers >> 8, LMGetKbdType(), 0, &dead, 16, &count, buffer);
    if (result != noErr || dead != 0) return nil;
    return [NSString stringWithCharacters:buffer length:count];
}
static NSString *unicodeCharacters(CGEventRef event) {
    UniChar buffer[64]{}; UniCharCount count = 0;
    CGEventKeyboardGetUnicodeString(event, 64, &count, buffer);
    return [NSString stringWithCharacters:buffer length:count];
}
struct Keyboard {
    std::shared_ptr<lvh::detail::macos::MacosInputState> state = std::make_shared<lvh::detail::macos::MacosInputState>();
    lvh::detail::macos::MacosKeyboard keyboard { state };
    ~Keyboard() { clearEvents(); }
    void key(uint16_t key, bool down, uint8_t flags = 0) {
        keyboard.submit(keyboard_event(key, !down, flags, false));
    }
};
static Keyboard *transportHost;
static int LiSendKeyboardEvent2(short code, char action, char, char flags) {
    transportHost->key(static_cast<uint16_t>(code), action == KEY_ACTION_DOWN, flags);
    return 0;
}
static int LiSendKeyboardEvent(short code, char action, char modifiers) {
    return LiSendKeyboardEvent2(code, action, modifiers, 0);
}
static int LiSendUtf8TextEvent(const char *text, unsigned int size) {
    transportHost->keyboard.type_text({ .text = std::string(text, size) });
    return 0;
}
// Only UITextField's text storage/caret and queue/timer boundaries are replaced.
// The actual client delegate, character encoding and wire flags are compiled.
@interface UITextRange : NSObject
@end
@implementation UITextRange
@end
@interface UITextField : NSObject
@property(copy) NSString *text;
@property(readonly) id endOfDocument;
- (UITextRange *)textRangeFromPosition:(id)from toPosition:(id)to;
- (void)setSelectedTextRange:(UITextRange *)range;
@end
@implementation UITextField
- (id)endOfDocument { return nil; }
- (UITextRange *)textRangeFromPosition:(id)from toPosition:(id)to { return nil; }
- (void)setSelectedTextRange:(UITextRange *)range {}
@end
@interface ClientTextEntry : NSObject
- (void)onKeyboardPressed:(UITextField *)field;
- (void)sendLowLevelEvent:(struct KeyEvent)event;
- (BOOL)textFieldShouldReturn:(UITextField *)field;
@end
static void runImmediately(dispatch_queue_t, dispatch_block_t block) { block(); }
#define dispatch_async runImmediately
#define usleep(duration) (void)(duration)
@implementation ClientTextEntry
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#include "text-entry.inc"
#pragma clang diagnostic pop
@end
#undef dispatch_async
#undef usleep
static void type(Keyboard &host, NSString *text) {
    transportHost = &host;
    UITextField *field = [UITextField new];
    field.text = [@"0" stringByAppendingString:text];
    [[ClientTextEntry new] onKeyboardPressed:field];
    transportHost = nullptr;
}
static void character(UniChar expected, const char *name = "German") {
    Keyboard host;
    auto client = [KeyboardSupport translateKeyEvent:expected withModifierFlags:0];
    NSString *text = [NSString stringWithCharacters:&expected length:1];
    type(host, text);
    if (client.keycode == 0) {
        check(posted.size() == 2 && [unicodeCharacters(posted[0]) isEqual:text]
            && [unicodeCharacters(posted[1]) isEqual:text],
            [NSString stringWithFormat:@"%s Unicode text %@ is preserved", name, text].UTF8String);
        return;
    }
    auto down = posted[client.modifier ? 1 : 0];
    auto up = posted[client.modifier ? 2 : 1];
    NSString *native = nativeCharacters(down);
    // Dead-key characters must arrive literally, without leaving composition pending.
    bool deadKey = expected == '^' || expected == 0x60 || expected == '~';
    bool literal = [native isEqual:text] || (deadKey && [unicodeCharacters(down) isEqual:text]);
    check(literal && CGEventGetIntegerValueField(down, kCGKeyboardEventKeycode) == CGEventGetIntegerValueField(up, kCGKeyboardEventKeycode)
        && host.state->keyboard_flags == 0,
        [NSString stringWithFormat:@"%s character %@ arrives unchanged with matching key-up (native %@)", name, text, native].UTF8String);
}
static void positional(uint16_t wire, NSString *expected) {
    Keyboard host;
    host.key(wire, true);
    check([nativeCharacters(posted.back()) isEqual:expected],
        [NSString stringWithFormat:@"German hardware position VK 0x%02x produces %@", wire, expected].UTF8String);
    host.key(wire, false);
}
int main() { @autoreleasepool {
    auto german = layout(CFSTR("com.apple.keylayout.German"));
    auto us = layout(CFSTR("com.apple.keylayout.US"));
    fixtureLayout = german;
    check(keyboard_event('Y', false, 0, false).uses_normalized_key_code
        && !keyboard_event('Z', false, SS_KBE_FLAG_NON_NORMALIZED, false).uses_normalized_key_code,
        "wire events preserve the positional versus character distinction");
    NSString *characters = @"öäüßÖÄÜ€";
    for (NSUInteger i = 0; i < characters.length; i++) character([characters characterAtIndex:i]);
    for (UniChar c = 32; c < 127; c++) character(c);
    fixtureLayout = us;
    for (UniChar c = 32; c < 127; c++) character(c, "US");
    fixtureLayout = german;
    positional('Y', @"z"); positional('Z', @"y");
    positional(0xBA, @"ö"); positional(0xDE, @"ä"); positional(0xDB, @"ü"); positional(0xBD, @"ß");
    {
        Keyboard host;
        host.key(0xA4, true); host.key('L', true);
        check([nativeCharacters(posted.back()) isEqual:@"@"], "German hardware Option+L still produces @");
        host.key('L', false); host.key(0xA4, false);
        check(host.state->keyboard_flags == 0, "hardware modifier releases leave no stuck Option key");
    }
    for (auto modifier : { uint16_t(0x5B), uint16_t(0xA2), uint16_t(0xA4) }) {
        Keyboard host;
        host.key(modifier, true);
        auto original = host.state->keyboard_flags;
        host.key('Z', true, SS_KBE_FLAG_NON_NORMALIZED);
        auto down = posted.back();
        check(CGEventGetIntegerValueField(down, kCGKeyboardEventKeycode) == kVK_ANSI_Y
            && (CGEventGetFlags(down) & original) == original,
            "logical z shortcuts use the German z key and preserve Command/Control/Option");
        host.key('Z', false, SS_KBE_FLAG_NON_NORMALIZED); host.key(modifier, false);
        check(host.state->keyboard_flags == 0, "shortcut releases clear the actual held modifiers");
    }
    {
        Keyboard host;
        host.key(0xA0, true); host.key('Z', true, SS_KBE_FLAG_NON_NORMALIZED);
        auto down = posted.back();
        check([nativeCharacters(down) isEqual:@"Z"], "Shift plus logical z produces German uppercase Z");
        host.key(0xA0, false); host.key('Z', false, SS_KBE_FLAG_NON_NORMALIZED);
        check(CGEventGetIntegerValueField(down, kCGKeyboardEventKeycode) == CGEventGetIntegerValueField(posted.back(), kCGKeyboardEventKeycode)
            && host.state->keyboard_flags == 0, "releasing Shift before the key still releases its original mapped key");
    }
    {
        Keyboard host;
        host.key('Z', true, SS_KBE_FLAG_NON_NORMALIZED);
        auto down = posted.back();
        fixtureLayout = us;
        host.key('Z', false, SS_KBE_FLAG_NON_NORMALIZED);
        check(CGEventGetIntegerValueField(down, kCGKeyboardEventKeycode) == kVK_ANSI_Y
            && CGEventGetIntegerValueField(posted.back(), kCGKeyboardEventKeycode) == kVK_ANSI_Y,
            "changing layout while a character key is held keeps its matching key-up");
        host.key('Z', true, SS_KBE_FLAG_NON_NORMALIZED);
        check(CGEventGetIntegerValueField(posted.back(), kCGKeyboardEventKeycode) == kVK_ANSI_Z,
            "the next stroke immediately follows the new active US layout");
        host.key('Z', false, SS_KBE_FLAG_NON_NORMALIZED);
    }
    fixtureLayout = german;
    {
        Keyboard host;
        unsigned before = layoutQueries;
        host.key('Y', true); host.key('Y', false);
        host.key(0x25, true); host.key(0x25, false);
        check(layoutQueries == before && CGEventGetIntegerValueField(posted.back(), kCGKeyboardEventKeycode) == kVK_LeftArrow,
            "physical and navigation events bypass character-layout lookup");
    }
    {
        Keyboard host;
        std::string text = "zy öäüß ÖÄÜ € @ [] {} \\ 😀 e\xCC\x81";
        NSString *expected = [NSString stringWithUTF8String:text.c_str()];
        type(host, expected);
        check(posted.size() == 2 && [unicodeCharacters(posted[0]) isEqual:expected]
            && [unicodeCharacters(posted[1]) isEqual:expected],
            "mixed UTF-8 text preserves umlauts, sharp s, symbols, surrogate pairs, and combining marks");
    }
    {
        Keyboard host;
        transportHost = &host;
        UITextField *field = [UITextField new];
        field.text = @"";
        ClientTextEntry *client = [ClientTextEntry new];
        [client onKeyboardPressed:field];
        [client textFieldShouldReturn:field];
        transportHost = nullptr;
        check(posted.size() == 4
            && CGEventGetIntegerValueField(posted[0], kCGKeyboardEventKeycode) == kVK_Delete
            && CGEventGetIntegerValueField(posted[1], kCGKeyboardEventKeycode) == kVK_Delete
            && CGEventGetIntegerValueField(posted[2], kCGKeyboardEventKeycode) == kVK_Return
            && CGEventGetIntegerValueField(posted[3], kCGKeyboardEventKeycode) == kVK_Return,
            "the real client keeps Backspace and Return as key-down/up events");
    }
    fixtureLayout = nullptr;
    {
        Keyboard host;
        host.key('Z', true, SS_KBE_FLAG_NON_NORMALIZED);
        check([unicodeCharacters(posted.back()) isEqual:@"z"],
            "missing layout data falls back to the exact Unicode character");
        host.key('Z', false, SS_KBE_FLAG_NON_NORMALIZED);
    }
    CFRelease(us); CFRelease(german);
    printf("Keyboard layout regression: %d failure(s).\n", failures);
    return failures ? 1 : 0;
} }
