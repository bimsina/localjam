#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint localjam_audio.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'localjam_audio'
  s.version          = '0.0.1'
  s.summary          = 'Sample-accurate scheduled audio playback for LocalJam.'
  s.description      = <<-DESC
Schedules AVAudioEngine playback at an exact mach-clock instant, with precise position readback and micro rate adjustment for drift correction.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'localjam_audio/Sources/localjam_audio/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'localjam_audio_privacy' => ['localjam_audio/Sources/localjam_audio/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
