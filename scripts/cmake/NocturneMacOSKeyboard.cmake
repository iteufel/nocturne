# Honor the protocol's positional/character distinction in both native layers.
# Generate overrides; never modify the pinned dependency checkouts.
function(nocturne_macos_keyboard_adapter source_root output)
    file(READ "${source_root}/src/platform/virtualhid_input.cpp" source)
    set(before [=[
#ifdef _WIN32
      event.uses_normalized_key_code = (static_cast<std::byte>(flags) & static_cast<std::byte>(SS_KBE_FLAG_NON_NORMALIZED)) == std::byte {};
      event.prefer_native_scan_code = config::input.always_send_scancodes;
#else
      (void) flags;
#endif
]=])
    set(after [=[
      event.uses_normalized_key_code = (static_cast<std::byte>(flags) & static_cast<std::byte>(SS_KBE_FLAG_NON_NORMALIZED)) == std::byte {};
#ifdef _WIN32
      event.prefer_native_scan_code = config::input.always_send_scancodes;
#endif
]=])
    string(FIND "${source}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned keyboard normalization changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" source "${source}")
    file(WRITE "${output}" "${source}")
endfunction()

function(nocturne_macos_keyboard_backend source_root output)
    file(READ "${source_root}/src/platform/macos/macos_backend.cpp" source)
    set(before "    class MacosKeyboard final: public BackendKeyboard {\n    public:")
    set(after "    class MacosKeyboard final: public BackendKeyboard {\n      nocturne::KeyboardLayout keyboard_layout_;\n    public:")
    string(FIND "${source}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS keyboard class changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" source "${source}")
    set(before "        CGEventPost(kCGSessionEventTap, keyboard_event);")
    set(after "        keyboard_layout_.apply(keyboard_event, event.key_code, event.uses_normalized_key_code, event.pressed);\n${before}")
    string(FIND "${source}" "${before}" position)
    if(position EQUAL -1)
        message(FATAL_ERROR "The pinned macOS keyboard submission changed; review the Nocturne overlay")
    endif()
    string(REPLACE "${before}" "${after}" source "${source}")
    file(WRITE "${output}" "#include \"KeyboardLayout.h\"\n${source}")
endfunction()
