#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint localjam_audio.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'localjam_audio'
  s.version          = '0.3.0'
  s.summary          = 'Sample-accurate scheduled audio playback for LocalJam.'
  s.description      = <<-DESC
Schedules AVAudioEngine playback at an exact mach-clock instant, with precise position readback and micro rate adjustment for drift correction.
                       DESC
  s.homepage         = 'https://github.com/bimsina/localjam'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Bibek Timsina'

  s.source           = { :path => '.' }
  # The Swift plugin plus the Objective-C exception catcher. Swift Package
  # Manager builds these as two targets; CocoaPods compiles them into one
  # module, where Swift sees the catcher through the umbrella header.
  s.source_files = 'localjam_audio/Sources/localjam_audio/**/*.swift',
                   'localjam_audio/Sources/localjam_audio_objc/**/*.{h,m}'
  s.public_header_files = 'localjam_audio/Sources/localjam_audio_objc/include/**/*.h'

  # Required-reason API declarations (mach_absolute_time → System boot time).
  s.resource_bundles = {'localjam_audio_privacy' => ['localjam_audio/Sources/localjam_audio/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
