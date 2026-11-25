const path = require('path');
const { getDefaultConfig } = require('expo/metro-config');

const config = getDefaultConfig(__dirname);

// The SDK packages are linked from ../packages; resolve their imports from this
// app's node_modules so only one react-native is bundled.
config.watchFolders = [path.resolve(__dirname, '../packages')];
config.resolver.nodeModulesPaths = [path.resolve(__dirname, 'node_modules')];
config.resolver.disableHierarchicalLookup = true;

module.exports = config;
