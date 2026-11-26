import NativeNottiOta from './NativeNottiOta';

export type CurrentRelease = {
  /** The Live update this session runs, or null for the bundle embedded in the binary. */
  releaseId: string | null;
  isEmbedded: boolean;
};

export type UpdateReadyEvent = {
  releaseId: string;
  /** The release was published as mandatory: ask the user to restart the app. */
  mandatory: boolean;
};

export type Subscription = {
  remove(): void;
};

export function getCurrentRelease(): Promise<CurrentRelease> {
  return NativeNottiOta.getCurrentRelease();
}

/**
 * Called when a Live update has been downloaded and verified. It loads on the next cold start;
 * the SDK never restarts the app itself.
 */
export function addUpdateReadyListener(
  listener: (event: UpdateReadyEvent) => void
): Subscription {
  return NativeNottiOta.otaUpdateReady(listener);
}
