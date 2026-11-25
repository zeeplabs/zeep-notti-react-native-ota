import ExpoModulesCore
import os

public class NottiOtaReactDelegateHandler: ExpoReactDelegateHandler {
  private static let log = Logger(subsystem: "com.notti.ota", category: "NottiOta")

  public override func bundleURL(reactDelegate: ExpoReactDelegate) -> URL? {
    Self.log.info("Live updates: Expo bundle hook called")
    return nil
  }
}
