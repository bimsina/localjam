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
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Required-reason API declarations (mach_absolute_time → System boot time).
  s.resource_bundles = {'localjam_audio_privacy' => ['localjam_audio/Sources/localjam_audio/PrivacyInfo.xcprivacy']}
end
