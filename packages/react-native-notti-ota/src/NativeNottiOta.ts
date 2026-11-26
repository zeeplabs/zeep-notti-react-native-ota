import {
  TurboModuleRegistry,
  type CodegenTypes,
  type TurboModule,
} from 'react-native';

export interface Spec extends TurboModule {
  getCurrentRelease(): Promise<{
    releaseId: string | null;
    isEmbedded: boolean;
  }>;
  readonly otaUpdateReady: CodegenTypes.EventEmitter<{
    releaseId: string;
    mandatory: boolean;
  }>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NottiOta');
