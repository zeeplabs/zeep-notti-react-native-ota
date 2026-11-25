require "json"

package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))

Pod::Spec.new do |s|
  s.name         = "NottiOtaExpo"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/zeeplabs/zeep-notti-react-native-ota"
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => "https://github.com/zeeplabs/zeep-notti-react-native-ota.git", :tag => "#{s.version}" }
  s.static_framework = true

  s.dependency "ExpoModulesCore"
  s.source_files = "**/*.swift"
  s.swift_version = "5.9"
end
