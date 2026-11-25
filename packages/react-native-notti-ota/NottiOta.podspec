require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NottiOta"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/zeeplabs/zeep-notti-react-native-ota"
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/zeeplabs/zeep-notti-react-native-ota.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.exclude_files = "ios/Tests/**/*"
  s.swift_version = "5.9"

  install_modules_dependencies(s)

  s.test_spec "Tests" do |test_spec|
    test_spec.source_files = "ios/Tests/**/*.swift"
  end
end
