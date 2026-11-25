import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  getCurrentRelease(): Promise<{
    releaseId: string | null;
    isEmbedded: boolean;
  }>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NottiOta');
