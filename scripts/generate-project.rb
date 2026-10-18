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
Dir.glob('{Sources/Client,Sources/Design}/**/*.{swift,m,h}').sort.each do |path|
  reference = group.new_file('../../' + path)
  target.source_build_phase.add_file_reference(reference) unless path.end_with?('.h')
end
icons = group.new_file('../../Resources/Client.xcassets')
target.resources_build_phase.add_file_reference(icons)
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
  settings['HEADER_SEARCH_PATHS'] << '$(PROJECT_DIR)/../../Sources/Client/Bridge'
  settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'DarkAppIcon'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['DEVELOPMENT_TEAM'] = ''
  settings['CODE_SIGN_ENTITLEMENTS'] = '../../Resources/Client.entitlements'
  settings['SUPPORTS_MACCATALYST'] = 'NO'
end
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
  settings['HEADER_SEARCH_PATHS'] = target.build_configurations.first.build_settings['HEADER_SEARCH_PATHS'] + ['$(CONFIGURATION_TEMP_DIR)/Nocturne.build/DerivedSources/CoreDataGenerated/Limelight']
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
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
host = mac.new_target(:application, 'Nocturne Server', :osx, '14.0')
group = mac.main_group.new_group('Server')
Dir.glob('{Sources/Server,Sources/Design}/**/*.swift').sort.each do |path|
  host.source_build_phase.add_file_reference(group.new_file(path))
end
host.resources_build_phase.add_file_reference(group.new_file('Resources/Server.xcassets'))
raise 'Run scripts/bootstrap.sh to fetch the server runtime.' unless File.executable?('Vendor/StreamingRuntime/Contents/Helpers/nocturne-stream-host')
phase = host.new_shell_script_build_phase('Package streaming server runtime')
phase.shell_path = '/bin/bash'
phase.shell_script = '"${SRCROOT}/scripts/package-streaming-server.sh"'
phase.always_out_of_date = '1'
kit = package(mac, '.')
product(mac, host, kit, 'NocturneKit'); product(mac, host, kit, 'NocturneHostKit')
host.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.server'
  settings['PRODUCT_NAME'] = 'Nocturne Server'
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
scheme.save_as('Nocturne.xcodeproj', 'Nocturne Server', true)
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
info['NSCameraUsageDescription'] = 'Scan the pairing QR code displayed by Nocturne Server on your Mac.'
info['UIApplicationSceneManifest'] = {'UIApplicationSupportsMultipleScenes' => false}
info['CFBundleURLTypes'] = [{'CFBundleURLName' => 'app.nocturne.pair', 'CFBundleURLSchemes' => ['nocturne']}]
orientations = %w[UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortraitUpsideDown]
info['UISupportedInterfaceOrientations'] = orientations
info['UISupportedInterfaceOrientations~ipad'] = orientations
Xcodeproj::Plist.write_to_path(info, 'Resources/Client-Info.plist')
