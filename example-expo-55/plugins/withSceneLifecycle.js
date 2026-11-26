// Example-only plugin: the Expo SDK 55 template uses the app-delegate life cycle, which the
// iOS 27 SDK (Xcode 27) refuses at launch. It moves the window and React Native start into a
// SceneDelegate so the example runs when built with Xcode 27.
const { withAppDelegate, withInfoPlist } = require('expo/config-plugins');

const START = `#if os(iOS) || os(tvOS)
    window = UIWindow(frame: UIScreen.main.bounds)
    factory.startReactNative(
      withModuleName: "main",
      in: window,
      launchOptions: launchOptions)
#endif
`;

const SCENE_DELEGATE = `
@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate,
          let factory = appDelegate.reactNativeFactory
    else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    appDelegate.window = window
    factory.startReactNative(withModuleName: "main", in: window, launchOptions: nil)
  }
}
`;

module.exports = function withSceneLifecycle(config) {
  config = withInfoPlist(config, (plistConfig) => {
    plistConfig.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [
          {
            UISceneConfigurationName: 'Default Configuration',
            UISceneDelegateClassName: 'SceneDelegate',
          },
        ],
      },
    };
    return plistConfig;
  });

  return withAppDelegate(config, (delegateConfig) => {
    const contents = delegateConfig.modResults.contents;
    if (contents.includes('class SceneDelegate')) return delegateConfig;
    if (!contents.includes(START)) {
      throw new Error('withSceneLifecycle: the AppDelegate template changed');
    }
    delegateConfig.modResults.contents = contents.replace(START, '') + SCENE_DELEGATE;
    return delegateConfig;
  });
};
