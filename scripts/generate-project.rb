#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

def package(project, path)
  reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  reference.relative_path = path
  project.root_object.package_references << reference
  reference
end

def product(project, target, package, name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = name
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

client = Xcodeproj::Project.open('Vendor/moonlight-ios/Moonlight.xcodeproj')
target = client.targets.find { |entry| entry.name == 'Moonlight' }
target.name = 'Nocturne'
target.product_reference.path = 'Nocturne.app'
target.source_build_phase.files.to_a.each do |build|
  build.remove_from_project if build.file_ref&.path&.end_with?('main.m')
end
group = client.main_group.new_group('Nocturne')
# Keep the fetched engine pristine. Build a tiny, deterministic source overlay for resizing controls.
original = File.read('Vendor/moonlight-ios/Limelight/Input/OnScreenControls.m')
marker = "- (void) updateControls {\n"
raise 'Upstream control layout changed; review the overlay.' unless original.scan(marker).length == 1
FileUtils.mkdir_p('.build/EngineOverrides')
File.write('.build/EngineOverrides/OnScreenControls.m', original.sub(marker, marker + File.read('Sources/Client/Bridge/OnScreenControlsLayout.inc') + "\n"))
target.source_build_phase.files.to_a.each do |build|
  build.remove_from_project if build.file_ref&.path&.end_with?('OnScreenControls.m')
end
target.source_build_phase.add_file_reference(group.new_file('../../.build/EngineOverrides/OnScreenControls.m'))
# Deterministic lifecycle overlays provide a completion after LiStopConnection.
# Resizing must never start a new global decoder while the old one is stopping.
def overlay(client_target, client_group, filename)
  source = File.read("Vendor/moonlight-ios/Limelight/#{filename}")
  revised = yield(source)
  name = File.basename(filename)
  File.write(".build/EngineOverrides/#{name}", "#import \"NocturneStreamLifecycle.h\"\n" + revised)
  client_target.source_build_phase.files.to_a.each do |build|
    build.remove_from_project if build.file_ref&.path&.end_with?(name)
  end
  client_target.source_build_phase.add_file_reference(client_group.new_file("../../.build/EngineOverrides/#{name}"))
end
def replace_once(source, before, after)
  raise 'Upstream streaming lifecycle changed; review the overlay.' unless source.scan(before).length == 1
  source.sub(before, after)
end
def replace_section(source, first, following, replacement)
  raise 'Upstream input changed; review the overlay.' unless source.scan(first).length == 1 && source.scan(following).length == 1
  start = source.index(first); finish = source.index(following)
  raise 'Upstream input section changed; review the overlay.' unless finish > start
  source[0...start] + replacement + source[finish..]
end
def input_methods(source, filename)
  raise 'Upstream input implementation changed; review the overlay.' unless source.match?(/\n@end\s*\z/)
  "#import \"NocturneStreamInput.h\"\n" + source.sub(/\n@end\s*\z/, "\n" + File.read("Sources/Client/Bridge/#{filename}") + "\n@end\n")
end
overlay(target, group, 'Stream/Connection.m') do |source|
  source = replace_once(source, 'static SDL_AudioDeviceID audioDevice;', "static SDL_AudioDeviceID audioDevice;\n#define NOCTURNE_ADAPTIVE_AUDIO 1\nstatic struct { uint64_t lastPacketMs; unsigned targetMs; bool hasPacket; } audioTiming;")
  source = replace_once(source, '    SDL_AudioSpec want, have;', "    SDL_AudioSpec want, have;\n    memset(&audioTiming, 0, sizeof(audioTiming));")
  source = replace_section(source, 'void ArDecodeAndPlaySample(', 'void ClStageStarting(', File.read('Sources/Client/Bridge/StreamAudioPlayback.inc'))
  source = replace_once(source, "    // Start playback\n    SDL_PauseAudioDevice(audioDevice, 0);", "    // Playback starts after StreamAudioPlayback primes the jitter cushion.")
  # Loopback is the remote QUIC proxy: retain WAN packet sizing and stream behavior.
  source = replace_once(source, 'if ([Utils isActiveNetworkVPN]) {', 'if ([Utils isActiveNetworkVPN] || [config.host isEqualToString:@"127.0.0.1"]) {')
  source = replace_once(source, "-(void) terminate\n{", "-(void) terminate { [self nocturneTerminateWithCompletion:nil]; }\n\n-(void)nocturneTerminateWithCompletion:(void (^)(void))completion\n{\n    [self cancel];")
  # A stop may win before the queued Connection operation has entered main().
  source = replace_once(source, "    [initLock lock];\n    LiStartConnection(", "    [initLock lock];\n    if (self.cancelled) { [initLock unlock]; return; }\n    LiStartConnection(")
  replace_once(source, "        LiStopConnection();\n        [initLock unlock];", "        LiStopConnection();\n        [initLock unlock];\n        if (completion) dispatch_async(dispatch_get_main_queue(), completion);")
end
overlay(target, group, 'Stream/StreamManager.m') do |source|
  source = replace_once(source, '    Connection* _connection;', "    Connection* _connection;\n    BOOL _nocturneStopping, _nocturneStopped;\n    NSMutableArray *_nocturneStopCallbacks;")
  source = replace_once(source, "- (void)main {", "- (void)main {\n    if (self.cancelled) return;")
  source = replace_once(source, '    // resumeApp and launchApp handle calling launchFailed', "    if (self.cancelled) return;\n    // resumeApp and launchApp handle calling launchFailed")
  source = replace_once(source, "    dispatch_async(dispatch_get_main_queue(), ^{\n        VideoDecoderRenderer*", "    dispatch_async(dispatch_get_main_queue(), ^{\n        if (self.cancelled) return;\n        VideoDecoderRenderer*")
  replace_once(source, "- (void) stopStream\n{\n    [_connection terminate];\n}", File.read('Sources/Client/Bridge/StreamManagerStop.inc'))
end
overlay(target, group, 'ViewControllers/StreamFrameViewController.m') do |source|
  source = replace_once(source, '- (void)willMoveToParentViewController:(UIViewController *)parent {', "- (void)nocturneStopWithCompletion:(void (^)(void))completion {\n    if (_streamMan) [_streamMan nocturneStopWithCompletion:completion];\n    else if (completion) completion();\n}\n\n- (void)willMoveToParentViewController:(UIViewController *)parent {")
  source = replace_section(source, '    // Only enable scroll and zoom in absolute touch mode', '    [self.view addSubview:_stageLabel];', "    [self nocturneSetAbsoluteTouchMode:_settings.absoluteTouchMode];\n\n")
  input_methods(source, 'StreamFrameInput.inc')
end
# Keep all input changes in reviewed overlays, leaving the pinned dependency intact.
overlay(target, group, 'Input/StreamView.m') do |source|
  source = "#import <objc/runtime.h>\n" + source
  source = replace_section(source, '- (CGSize) getVideoAreaSize {', '- (CGPoint) adjustCoordinatesForVideoArea:', "- (CGSize) getVideoAreaSize {\n    return NocturneVideoAreaSize(self.bounds.size, streamAspectRatio, self.nocturneFillEntireScreen);\n}\n\n")
  source = replace_section(source, '    CGSize videoSize;', '    videoOrigin = CGPointMake', "    CGSize videoSize = [self getVideoAreaSize];\n    CGPoint videoOrigin;\n")
  source = replace_once(source, '    NSInteger lastMouseButtonMask;', "    NSInteger lastMouseButtonMask;\n    NSMapTable<UITouch *, NSNumber *> *nocturneMouseTouches;\n    NSMutableSet<UITouch *> *nocturneActiveTouches;\n    NSHashTable<UITouch *> *nocturneIgnoredTouches;")
  source = replace_once(source, '    NSMutableSet* keysDown;', "    NSMutableSet* keysDown;\n    NSMutableDictionary<NSNumber *, UIPress *> *nocturnePressedKeys;\n    BOOL nocturneControlsKeyDown;")
  source = replace_section(source, '- (void)pressesBegan:', '- (void)touchesEnded:', File.read('Sources/Client/Bridge/StreamKeyboardInput.inc'))
  source = replace_section(source, '        if ([[event allTouches] count] == 3) {', '- (UIBarButtonItem *)createButtonWithImageNamed:', "        if ([[event allTouches] count] == 3) [self nocturneToggleKeyboard];\n    }\n}\n\n")
  source = replace_section(source, '- (BOOL)handleMouseButtonEvent:', '- (void)touchesMoved:', '')
  raise 'Upstream mouse routing changed; review the overlay.' unless source.scan('if ([GCMouse current] != nil)').length == 2
  source = source.gsub('if ([GCMouse current] != nil)', 'if (NocturneUsesRelativeMouse(self))')
  source = replace_once(source, '    Log(LOG_D, @"Touch down");', "    if (nocturneIgnoredTouches.count) {\n        for (UITouch *touch in touches) [nocturneIgnoredTouches addObject:touch];\n        return;\n    }\n    if (!nocturneActiveTouches) nocturneActiveTouches = [NSMutableSet set];\n    [nocturneActiveTouches unionSet:touches];\n    Log(LOG_D, @\"Touch down\");")
  source = replace_once(source, "    if (![onScreenControls handleTouchMovedEvent:touches]) {", "    if (nocturneIgnoredTouches.count) return;\n    if (![onScreenControls handleTouchMovedEvent:touches]) {")
  source = replace_once(source, '    Log(LOG_D, @"Touch up");', "    if (nocturneIgnoredTouches.count) {\n        for (UITouch *touch in touches) [nocturneIgnoredTouches removeObject:touch];\n        return;\n    }\n    [nocturneActiveTouches minusSet:touches];\n    Log(LOG_D, @\"Touch up\");")
  source = replace_once(source, "- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {\n", "- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {\n    if ([self handleMouseButtonEvent:BUTTON_ACTION_RELEASE forTouches:touches withEvent:event]) return;\n    if (nocturneIgnoredTouches.count) {\n        for (UITouch *touch in touches) [nocturneIgnoredTouches removeObject:touch];\n        return;\n    }\n    [nocturneActiveTouches minusSet:touches];\n    [onScreenControls handleTouchUpEvent:touches];\n")
  source = source.gsub(/LiSendMouseButtonEvent\((BUTTON_ACTION_(?:PRESS|RELEASE)), (\[self buttonFromX1ButtonCode:button\])\);/, '[self nocturneSendMouseButton:\1 button:\2];')
  input_methods(source, 'StreamViewInput.inc')
end
overlay(target, group, 'Stream/VideoDecoderRenderer.m') do |source|
  # UIKit switches run-loop modes during touch tracking. Default-only delivery
  # freezes decoding until the gesture ends, then drains a burst of old frames.
  source = replace_once(source, 'forMode:NSDefaultRunLoopMode];', 'forMode:NSRunLoopCommonModes];')
  source = replace_once(source, '    CADisplayLink* _displayLink;', "    CADisplayLink* _displayLink;\n    NocturneVideoPacer nocturnePacer;")
  source = replace_once(source, '    self->frameRate = frameRate;', "    self->frameRate = frameRate;\n    NocturneVideoPacerReset(&nocturnePacer, frameRate, framePacing);")
  source = replace_section(source, '- (void)displayLinkCallback:', '- (void)stop', File.read('Sources/Client/Bridge/StreamVideoPlayback.inc'))
  source = replace_section(source, '    CGSize videoSize;', '    displayLayer.position =', "    CGSize videoSize = [_view getVideoAreaSize];\n")
  "#import \"NocturneStreamInput.h\"\n#import \"StreamVideoPacing.h\"\n" + source
end
overlay(target, group, 'Input/ControllerSupport.m') do |source|
  source = replace_once(source, '@implementation ControllerSupport {', "@implementation ControllerSupport {\n    NSUInteger nocturneMouseButtons;")
  source = replace_once(source, '        self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;', "        if (![self nocturneUsesRelativeMouse]) return;\n        self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;")
  source = replace_once(source, '            LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);', '            [self nocturneSendMouseMoveX:truncatedDeltaX y:truncatedDeltaY];')
  raise 'Upstream mouse buttons changed; review the overlay.' unless source.scan('LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,').length == 5
  source = source.gsub(/LiSendMouseButtonEvent\(pressed \? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, (BUTTON_\w+)\);/, '[self nocturneHandleMouseButton:pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE button:\1];')
  source = replace_once(source, "-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {", "-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {\n    [self nocturneReleaseMouseButtons];")
  source = replace_once(source, "-(void) cleanup\n{", "-(void) cleanup\n{\n    [self nocturneReleaseMouseButtons];")
  input_methods(source, 'ControllerMouseInput.inc')
end
overlay(target, group, 'Input/RelativeTouchHandler.m') do |source|
  source = replace_once(source, '    UIView* view;', "    __weak UIView* view;\n    NSUInteger nocturneTapGeneration;\n    int nocturneTapButton;")
  source = replace_once(source, "- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {", "- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {\n    [self nocturneCancelTap];")
  source = replace_once(source, '    peakTouchCount = [[event allTouches] count];', '    peakTouchCount = MAX(peakTouchCount, [[event allTouches] count]);')
  source = replace_section(source, '- (void)touchesEnded:', '- (void)touchesCancelled:', '')
  source = replace_once(source, "- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {", "- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {\n    [self nocturneCancelTap];")
  source = source.gsub(/LiSendMouseButtonEvent\((BUTTON_ACTION_(?:PRESS|RELEASE)), (BUTTON_\w+)\);/, '[(StreamView *)view nocturneSendMouseButton:\1 button:\2];')
  input_methods(source, 'RelativeTouchInput.inc')
end
overlay(target, group, 'Input/AbsoluteTouchHandler.m') do |source|
  source = replace_once(source, '    StreamView* view;', '    __weak StreamView* view;')
  source = replace_once(source, '    if ([[event allTouches] count] == [touches count]) {', '    if ([touches containsObject:lastTouchDown] || [[event allTouches] count] == [touches count]) {')
  source = replace_once(source, "    // Treat this as a normal touchesEnded event\n    [self touchesEnded:touches withEvent:event];", "    [longPressTimer invalidate]; longPressTimer = nil;\n    [view nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:BUTTON_LEFT];\n    [view nocturneSendMouseButton:BUTTON_ACTION_RELEASE button:BUTTON_RIGHT];\n    lastTouchDown = lastTouchUp = nil;")
  source = source.gsub(/LiSendMouseButtonEvent\((BUTTON_ACTION_(?:PRESS|RELEASE)), (BUTTON_\w+)\);/, '[view nocturneSendMouseButton:\1 button:\2];')
  "#import \"NocturneStreamInput.h\"\n" + source
end
Dir.glob('{Sources/Client,Sources/Design}/**/*.{swift,m,h}').sort.each do |path|
  reference = group.new_file('../../' + path)
  target.source_build_phase.add_file_reference(reference) unless path.end_with?('.h')
end
icons = group.new_file('../../Resources/Client.xcassets')
target.resources_build_phase.add_file_reference(icons)
target.resources_build_phase.add_file_reference(group.new_file('../../Resources/PrivacyInfo.xcprivacy'))
kit = package(client, '../..'); terminal = package(client, '../SwiftTerm')
product(client, target, kit, 'NocturneKit'); product(client, target, terminal, 'SwiftTerm')
target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'Nocturne'
  settings['PRODUCT_MODULE_NAME'] = 'Nocturne'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.client'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['INFOPLIST_FILE'] = '../../Resources/Client-Info.plist'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = '../../Sources/Client/Bridge/Nocturne-Bridging-Header.h'
  settings['SWIFT_OBJC_INTERFACE_HEADER_NAME'] = 'Moonlight-Swift.h'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  # The pinned client names Xcode.app explicitly. CI selects another Xcode,
  # so importing both toolchains' headers redefines SwiftBridging.
  settings['HEADER_SEARCH_PATHS'].map! do |path|
    path.sub('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include',
      '$(TOOLCHAIN_DIR)/usr/include')
  end
  settings['HEADER_SEARCH_PATHS'] << '$(PROJECT_DIR)/../../Sources/Client/Bridge'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'DarkAppIcon'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  # Archive overrides belong to the app, not SwiftPM tools or resource bundles.
  settings['NOCTURNE_CODE_SIGN_STYLE'] = 'Automatic'
  settings['NOCTURNE_CODE_SIGN_IDENTITY'] = 'Apple Development'
  settings['CODE_SIGN_STYLE'] = '$(NOCTURNE_CODE_SIGN_STYLE)'
  settings['CODE_SIGN_IDENTITY'] = '$(NOCTURNE_CODE_SIGN_IDENTITY)'
  settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = '$(NOCTURNE_CODE_SIGN_IDENTITY)'
  settings['DEVELOPMENT_TEAM'] = '$(NOCTURNE_DEVELOPMENT_TEAM)'
  settings['PROVISIONING_PROFILE_SPECIFIER'] = '$(NOCTURNE_PROVISIONING_PROFILE_SPECIFIER)'
  settings['CODE_SIGN_ENTITLEMENTS'] = '../../Resources/Client.entitlements'
  settings['SUPPORTS_MACCATALYST'] = 'NO'
end
files = client.new_target(:app_extension, 'Nocturne Files', :ios, '17.0')
files_group = client.main_group.new_group('Nocturne Files')
Dir.glob('Sources/FileProvider/**/*.swift').sort.each do |path|
  files.source_build_phase.add_file_reference(files_group.new_file('../../' + path))
end
product(client, files, kit, 'NocturneKit')
files.resources_build_phase.add_file_reference(files_group.new_file('../../Resources/PrivacyInfo.xcprivacy'))
files.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'Nocturne Files'
  settings['PRODUCT_MODULE_NAME'] = 'NocturneFiles'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.client.files'
  settings['INFOPLIST_FILE'] = '../../Resources/Files-Info.plist'
  settings['CODE_SIGN_ENTITLEMENTS'] = '../../Resources/Files.entitlements'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SKIP_INSTALL'] = 'YES'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['NOCTURNE_CODE_SIGN_STYLE'] = 'Automatic'
  settings['NOCTURNE_CODE_SIGN_IDENTITY'] = 'Apple Development'
  settings['CODE_SIGN_STYLE'] = '$(NOCTURNE_CODE_SIGN_STYLE)'
  settings['CODE_SIGN_IDENTITY'] = '$(NOCTURNE_CODE_SIGN_IDENTITY)'
  settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = '$(NOCTURNE_CODE_SIGN_IDENTITY)'
  settings['DEVELOPMENT_TEAM'] = '$(NOCTURNE_DEVELOPMENT_TEAM)'
  settings['PROVISIONING_PROFILE_SPECIFIER'] = '$(NOCTURNE_FILES_PROVISIONING_PROFILE_SPECIFIER)'
  settings['SUPPORTS_MACCATALYST'] = 'NO'
end
target.add_dependency(files)
embed_files = target.new_copy_files_build_phase('Embed Files extension')
embed_files.dst_subfolder_spec = '13'
embed_files.add_file_reference(files.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

client_tests = client.new_target(:unit_test_bundle, 'NocturneClientTests', :ios, '17.0')
client_tests.add_dependency(target)
test_group = client.main_group.new_group('Nocturne Client Tests')
Dir.glob('Tests/Client/**/*.{m,swift}').sort.each do |path|
  client_tests.source_build_phase.add_file_reference(test_group.new_file('../../' + path))
end
client_tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.client.tests'
  settings['PRODUCT_NAME'] = 'NocturneClientTests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Nocturne.app/Nocturne'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  settings['HEADER_SEARCH_PATHS'] = target.build_configurations.first.build_settings['HEADER_SEARCH_PATHS'] + ['$(CONFIGURATION_TEMP_DIR)/Nocturne.build/DerivedSources', '$(CONFIGURATION_TEMP_DIR)/Nocturne.build/DerivedSources/CoreDataGenerated/Limelight']
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = ''
end
client.save('Vendor/moonlight-ios/Nocturne.xcodeproj')
client = Xcodeproj::Project.open('Vendor/moonlight-ios/Nocturne.xcodeproj')
target = client.targets.find { |entry| entry.name == 'Nocturne' }
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target); scheme.set_launch_target(target)
scheme.add_test_target(client.targets.find { |entry| entry.name == 'NocturneClientTests' })
scheme.save_as('Vendor/moonlight-ios/Nocturne.xcodeproj', 'Nocturne', true)

mac = Xcodeproj::Project.new('Nocturne.xcodeproj')
host = mac.new_target(:application, 'Nocturne Mac', :osx, '14.0')
host.product_name = 'Nocturne'
host.product_reference.path = 'Nocturne.app'
group = mac.main_group.new_group('Server')
Dir.glob('{Sources/Server,Sources/Design}/**/*.swift').sort.each do |path|
  host.source_build_phase.add_file_reference(group.new_file(path))
end
host.resources_build_phase.add_file_reference(group.new_file('Resources/Server.xcassets'))
# Client-only bootstrap does not need the Mac runtime. Packaging validates it
# when the server is actually built.
phase = host.new_shell_script_build_phase('Package streaming server runtime')
phase.shell_path = '/bin/bash'
phase.shell_script = '"${SRCROOT}/scripts/package-streaming-server.sh"'
phase.always_out_of_date = '1'
kit = package(mac, '.')
product(mac, host, kit, 'NocturneKit'); product(mac, host, kit, 'NocturneHostKit')
product(mac, host, kit, 'NocturneMacClient')
host.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.server'
  settings['PRODUCT_NAME'] = 'Nocturne'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_STRICT_CONCURRENCY'] = 'minimal'
  settings['INFOPLIST_FILE'] = 'Resources/Server-Info.plist'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'ServerAppIcon'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = ''
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'Resources/Server.entitlements'
  settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
end
mac.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host); scheme.set_launch_target(host)
scheme.save_as('Nocturne.xcodeproj', 'Nocturne Mac', true)
workspace = Xcodeproj::Workspace.new('Nocturne.xcodeproj', 'Vendor/moonlight-ios/Nocturne.xcodeproj')
workspace.save_as('Nocturne.xcworkspace')

info = Xcodeproj::Plist.read_from_path('Vendor/moonlight-ios/Limelight/Limelight-Info.plist')
%w[UIMainStoryboardFile UIMainStoryboardFile~ipad UIRequiredDeviceCapabilities UILaunchStoryboardName].each { |key| info.delete(key) }
info['CFBundleDisplayName'] = 'Nocturne'
info['UIRequiresFullScreen'] = false
info['UIStatusBarHidden'] = false
info['UIViewControllerBasedStatusBarAppearance'] = true
info['UILaunchScreen'] = {}
info['NSBonjourServices'] = ['_nvstream._tcp', '_nocturne._tcp']
info['NSLocalNetworkUsageDescription'] = 'Find your computers and connect directly for streaming, terminal access, and file transfer.'
info['NSBluetoothAlwaysUsageDescription'] = 'Connect compatible Bluetooth mice and accessories to Nocturne.'
info['NSBluetoothPeripheralUsageDescription'] = 'Connect compatible Bluetooth mice and accessories to Nocturne.'
info['NSCameraUsageDescription'] = 'Scan the pairing QR code displayed by Nocturne on your Mac.'
info['NSMicrophoneUsageDescription'] = 'Send your microphone to your paired Mac for voice chat in Discord and games when you unmute a stream.'
info['UIApplicationSceneManifest'] = {
  'UIApplicationSupportsMultipleScenes' => true,
  'UISceneConfigurations' => {'UIWindowSceneSessionRoleApplication' => [
    {'UISceneConfigurationName' => 'Nocturne', 'UISceneDelegateClassName' => '$(PRODUCT_MODULE_NAME).DarkSceneDelegate'}
  ]}
}
info.delete('CFBundleURLTypes') # Pairing invitations are accepted only by the in-app QR scanner.
orientations = %w[UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortraitUpsideDown]
info['UISupportedInterfaceOrientations'] = orientations
info['UISupportedInterfaceOrientations~ipad'] = orientations
Xcodeproj::Plist.write_to_path(info, 'Resources/Client-Info.plist')
