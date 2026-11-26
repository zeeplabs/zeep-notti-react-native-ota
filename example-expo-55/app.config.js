// The e2e flows (e2e/run.sh) point the example at the local Notti they set up;
// without those variables app.json is used as is.
const { readFileSync } = require('node:fs');

module.exports = ({ config }) => {
  const env = process.env;
  if (!env.NOTTI_APP_ID) return config;
  return {
    ...config,
    plugins: config.plugins.map((plugin) =>
      Array.isArray(plugin) && plugin[0] === 'react-native-notti-ota'
        ? [
            plugin[0],
            {
              ...plugin[1],
              appId: env.NOTTI_APP_ID,
              baseUrl: env.NOTTI_E2E_BASE_URL,
              clientKey: env.NOTTI_E2E_CLIENT_KEY,
              publicKeys: [readFileSync(env.NOTTI_E2E_PUBLIC_PEM_FILE, 'utf8')],
            },
          ]
        : plugin
    ),
  };
};
