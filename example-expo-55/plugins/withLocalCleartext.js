// Example app only: lets the Release build reach the local Notti over plain HTTP
// (http://localhost:18080 through adb reverse in the e2e flows). Never ship this.
const { withAndroidManifest } = require('expo/config-plugins');

module.exports = function withLocalCleartext(config) {
  return withAndroidManifest(config, (mod) => {
    mod.modResults.manifest.application[0].$['android:usesCleartextTraffic'] = 'true';
    return mod;
  });
};
