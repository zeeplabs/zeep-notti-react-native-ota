import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import { VARIANT } from './variant';

if (VARIANT === 'crash') {
  throw new Error('Live updates e2e: crash release');
}
if (VARIANT === 'hang') {
  const start = Date.now();
  while (Date.now() >= start) {}
}

export default function App() {
  return (
    <View style={styles.container}>
      <Text testID="ota-variant">Live update: {VARIANT}</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
  },
});
