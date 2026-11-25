import ExpoModulesCore
import NottiOta
import os

/// Loads the bundle Notti Live updates selected, through Expo's supported bundle hook. Returning
/// nil (Debug builds, no configuration, embedded bundle) lets Expo use its default.
public class NottiOtaReactDelegateHandler: ExpoReactDelegateHandler {
  private static let log = Logger(subsystem: "com.notti.ota", category: "NottiOta")

  public override func bundleURL(reactDelegate: ExpoReactDelegate) -> URL? {
    let url = NottiOTA.bundleURL()
    Self.log.info("Live updates: Expo bundle hook called (Live update selected: \(url != nil, privacy: .public))")
    return url
  }
}
