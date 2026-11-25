const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const packages = path.resolve(__dirname, '../packages');

// The SDK packages are linked from ../packages; without these, Metro would
// resolve react-native from the monorepo root and bundle two copies.
const config = {
  watchFolders: [packages],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    disableHierarchicalLookup: true,
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
