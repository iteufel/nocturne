#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <array>
#include <cstdint>
#include <optional>
#include <unordered_map>

namespace nocturne {
// Moonlight sends hardware positions as US-normalized virtual keys. Its text
// keyboard encodes ASCII characters with a US table and NON_NORMALIZED instead.
// Keep those contracts separate; only character events need layout resolution.
class KeyboardLayout {
    struct Mapping {
        CGKeyCode key;
        CGEventFlags flags;
        UniChar character;
        bool unicode;
    };
    std::unordered_map<std::uint16_t, Mapping> held_;

    static std::optional<UniChar> character(std::uint16_t key, CGEventFlags flags) {
        const bool shift = (flags & kCGEventFlagMaskShift) != 0;
        if (key >= 'A' && key <= 'Z') return static_cast<UniChar>(shift ? key : key + ('a' - 'A'));
        if (key >= '0' && key <= '9') {
            constexpr char shifted[] = ")!@#$%^&*(";
            return static_cast<UniChar>(shift ? shifted[key - '0'] : key);
        }
        switch (key) {
            case 0x20: return u' ';
            case 0xBA: return shift ? u':' : u';';
            case 0xBB: return shift ? u'+' : u'=';
            case 0xBC: return shift ? u'<' : u',';
            case 0xBD: return shift ? u'_' : u'-';
            case 0xBE: return shift ? u'>' : u'.';
            case 0xBF: return shift ? u'?' : u'/';
            case 0xC0: return shift ? 0x7E : 0x60;
            case 0xDB: return shift ? u'{' : u'[';
            case 0xDC: return shift ? u'|' : u'\\';
            case 0xDD: return shift ? u'}' : u']';
            case 0xDE: return shift ? u'"' : u'\'';
            default: return std::nullopt;
        }
    }

    static Mapping resolve(UniChar text, CGKeyCode fallback, CGEventFlags original) {
        constexpr CGEventFlags shiftFlags = kCGEventFlagMaskShift | NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK;
        constexpr CGEventFlags optionFlags = kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK;
        // Shift in a text packet describes its character, not the modifiers
        // needed on this Mac. Preserve actual shortcut modifiers independently.
        auto preserved = original & ~(shiftFlags | optionFlags | kCGEventFlagMaskAlphaShift);
        preserved |= original & optionFlags;
        Mapping mapping {fallback, preserved, text,
            (original & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) == 0};

        auto source = TISCopyCurrentKeyboardLayoutInputSource();
        if (!source) return mapping;
        auto data = static_cast<CFDataRef>(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData));
        if (!data) {
            CFRelease(source);
            return mapping;
        }
        const auto layout = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
        const auto keyboardType = LMGetKbdType();
        constexpr std::array<UInt32, 4> modifiers {0, shiftKey, optionKey, shiftKey | optionKey};
        for (auto modifier : modifiers) {
            for (UInt16 key = 0; key < 128; key++) {
                UniChar buffer[8] {};
                UniCharCount length = 0;
                UInt32 dead = 0;
                auto status = UCKeyTranslate(layout, key, kUCKeyActionDown, modifier >> 8,
                    keyboardType, 0, &dead, 8, &length, buffer);
                // A literal accent must not begin a dead-key composition.
                if (status != noErr || dead != 0 || length != 1 || buffer[0] != text) continue;
                mapping.key = key;
                if (modifier & shiftKey) mapping.flags |= kCGEventFlagMaskShift | NX_DEVICELSHIFTKEYMASK;
                if (modifier & optionKey) mapping.flags |= kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK;
                CFRelease(source);
                return mapping;
            }
        }
        CFRelease(source);
        // Unicode preserves literal accents and characters absent from a
        // layout, including input sources that do not expose layout data.
        return mapping;
    }

public:
    void apply(CGEventRef event, std::uint16_t key, bool positional, bool pressed) {
        if (positional) return;
        const auto text = character(key, CGEventGetFlags(event));
        if (!text) return;
        auto held = held_.find(key);
        if (held == held_.end()) {
            if (!pressed) return;
            const auto physical = static_cast<CGKeyCode>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
            held = held_.emplace(key, resolve(*text, physical, CGEventGetFlags(event))).first;
        }
        const auto mapping = held->second;
        CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, mapping.key);
        CGEventSetFlags(event, mapping.flags);
        if (mapping.unicode) CGEventKeyboardSetUnicodeString(event, 1, &mapping.character);
        // Keep the original resolved position through key-up even if the user
        // changes layouts or releases Shift while this key is held.
        if (!pressed) held_.erase(held);
    }
};
}
