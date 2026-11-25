import NativeNottiOta from './NativeNottiOta';

export type CurrentRelease = {
  releaseId: string | null;
  isEmbedded: boolean;
};

export function getCurrentRelease(): Promise<CurrentRelease> {
  return NativeNottiOta.getCurrentRelease();
}
