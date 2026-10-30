#!/usr/bin/env ruby
# Build only the production App Intent declaration and its small value-type dependency.
# Runs Xcode's real metadata exporter for app and extension; never launches either.
require 'xcodeproj'
require 'fileutils'
require 'json'

root = File.expand_path('..', __dir__)
check = File.join(root, '.build/attention-metadata')
FileUtils.mkdir_p(check)
project_path = File.join(check, 'AttentionMetadata.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.root_object.development_region = 'en'
project.root_object.known_regions = %w[en de fr it es Base]
source = File.join(check, 'AttentionActivity.swift')
original = File.read(File.join(root, 'Sources/AttentionActivity/AttentionActivity.swift'))
File.write(source, original)
File.write(File.join(check, 'Entry.swift'), <<~SWIFT)
  import Foundation
  import NocturneKit
  @main struct MetadataEntry { static func main() {} }
  // Compile-only app boundary. No permission action, notification, call or push is performed.
  @MainActor final class AgentAttentionCenter {
      static let shared = AgentAttentionCenter()
      func decide(id: String, host: String, provider: String, session: String, allow: Bool) async throws {
          throw AttentionIntentError.unavailable
      }
  }
SWIFT

def add_sources(project, target, paths)
  paths.each { |path| target.source_build_phase.add_file_reference(project.main_group.new_file(path)) }
end
kit = project.new_target(:framework, 'NocturneKit', :ios, '17.0')
add_sources(project, kit, [File.join(root, 'Sources/Shared/AgentAttention.swift')])
kit.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'app.nocturne.metadata.kit'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
end
products = [[:application, 'MetadataApp'], [:app_extension, 'MetadataWidget']].map do |type, name|
  target = project.new_target(type, name, :ios, '17.0')
  add_sources(project, target, [source, File.join(check, 'Entry.swift')])
  target.add_dependency(kit)
  target.frameworks_build_phase.add_file_reference(kit.product_reference)
  table = project.main_group.new_variant_group('AppIntents.strings')
  %w[en de fr it es].each do |language|
    child = table.new_file(File.join(root, "Resources/Localization/AttentionIntents/#{language}.lproj/AppIntents.strings"))
    child.name = language
  end
  target.resources_build_phase.add_file_reference(table)
  info = {
    'CFBundleIdentifier' => "app.nocturne.metadata.#{name.downcase}",
    'CFBundleExecutable' => '$(EXECUTABLE_NAME)', 'CFBundleName' => name,
    'CFBundlePackageType' => type == :application ? 'APPL' : 'XPC!',
    'CFBundleShortVersionString' => '1.0', 'CFBundleVersion' => '1',
    'CFBundleDevelopmentRegion' => 'en', 'CFBundleLocalizations' => %w[en de fr it es]
  }
  info['NSExtension'] = { 'NSExtensionPointIdentifier' => 'com.apple.widgetkit-extension' } if type == :app_extension
  plist = File.join(check, "#{name}-Info.plist")
  Xcodeproj::Plist.write_to_path(info, plist)
  target.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = info['CFBundleIdentifier']
    config.build_settings['INFOPLIST_FILE'] = plist
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'NOCTURNE_ATTENTION_WIDGET' if type == :app_extension
    config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES' if type == :app_extension
  end
  target
end
project.save
scheme = Xcodeproj::XCScheme.new
products.each { |target| scheme.add_build_target(target) }
scheme.save_as(project_path, 'AttentionMetadata', true)
command = ['xcodebuild', '-project', project_path, '-scheme', 'AttentionMetadata',
           '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
           '-derivedDataPath', File.join(check, 'DerivedData'), 'CODE_SIGNING_ALLOWED=NO', 'build']
log = File.join(check, 'build.log')
unless system(*command, out: log, err: [:child, :out])
  warn File.read(log).lines.grep(/error:|ExtractAppIntentsMetadata|BUILD FAILED/).join
  abort "App Intents metadata export failed. Full log: #{log}"
end
verify = lambda do
 products.each do |target|
  suffix = target.product_reference.path
  product = File.join(check, 'DerivedData/Build/Products/Debug-iphonesimulator', suffix)
  abort "Missing actual metadata export in #{product}" unless File.file?(File.join(product, 'Metadata.appintents/extract.actionsdata'))
  metadata = JSON.parse(File.read(File.join(product, 'Metadata.appintents/extract.actionsdata')))
  action = metadata.fetch('actions').fetch('AttentionDecisionIntent')
  resources = [action.fetch('title')] + action.fetch('parameters').map { |parameter| parameter.fetch('title') }
  expected = ['Decide pending Nocturne request', 'Request', 'Host', 'Provider', 'Session', 'Allow once']
  abort "Wrong extracted metadata table: #{target.name}" unless resources.map { |r| r['key'] } == expected && resources.all? { |r| r['table'] == 'AppIntents' }
  %w[en de fr it es].each do |language|
    abort "Missing main-bundle intent table: #{target.name}/#{language}" unless File.file?(File.join(product, "#{language}.lproj/AppIntents.strings"))
  end
 end
end
verify.call
puts 'PASS: real App Intents metadata export and five main-bundle tables in app and extension'
if ARGV.include?('--verify-rejection')
  begin
    # Demonstrate the former SDK-typable mistake is rejected by the real exporter.
    File.write(source, original.gsub('table: "AppIntents"', 'bundle: .atURL(URL(fileURLWithPath: "/"))'))
    rejection_log = File.join(check, 'rejection.log')
    passed = system(*command, out: rejection_log, err: [:child, :out])
    message = File.read(rejection_log)
    abort 'Metadata regression probe did not reject a custom bundle' if passed || !message.include?("AppIntents requires 'LocalizedStringResource' to use the main bundle")
    puts 'PASS: real metadata exporter rejects the previous custom-bundle regression'
  ensure
    File.write(source, original)
  end
  abort "Restoring the valid metadata build failed: #{log}" unless system(*command, out: log, err: [:child, :out])
  verify.call
end
