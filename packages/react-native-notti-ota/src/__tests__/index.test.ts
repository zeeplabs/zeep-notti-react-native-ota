import { beforeEach, describe, expect, it, jest } from '@jest/globals';

type Listener = (event: { releaseId: string; mandatory: boolean }) => void;

const mockListeners = new Set<Listener>();
const mockGetCurrentRelease = jest.fn(async () => ({
  releaseId: null as string | null,
  isEmbedded: true,
}));

jest.mock('../NativeNottiOta', () => ({
  __esModule: true,
  default: {
    getCurrentRelease: () => mockGetCurrentRelease(),
    otaUpdateReady: (listener: Listener) => {
      mockListeners.add(listener);
      return { remove: () => mockListeners.delete(listener) };
    },
  },
}));

import { addUpdateReadyListener, getCurrentRelease } from '../index';

function emit(event: { releaseId: string; mandatory: boolean }) {
  mockListeners.forEach((listener) => listener(event));
}

beforeEach(() => {
  mockListeners.clear();
});

describe('getCurrentRelease', () => {
  it('reports the embedded bundle', async () => {
    await expect(getCurrentRelease()).resolves.toEqual({
      releaseId: null,
      isEmbedded: true,
    });
  });

  it('reports the Live update the session runs', async () => {
    mockGetCurrentRelease.mockResolvedValueOnce({
      releaseId: '7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b',
      isEmbedded: false,
    });
    await expect(getCurrentRelease()).resolves.toEqual({
      releaseId: '7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b',
      isEmbedded: false,
    });
  });
});

describe('addUpdateReadyListener', () => {
  it('delivers every ready release, mandatory or not', () => {
    const listener = jest.fn();
    addUpdateReadyListener(listener);

    emit({ releaseId: 'a', mandatory: true });
    emit({ releaseId: 'b', mandatory: false });

    expect(listener.mock.calls).toEqual([
      [{ releaseId: 'a', mandatory: true }],
      [{ releaseId: 'b', mandatory: false }],
    ]);
  });

  it('stops after remove()', () => {
    const removed = jest.fn();
    const kept = jest.fn();
    const subscription = addUpdateReadyListener(removed);
    addUpdateReadyListener(kept);

    subscription.remove();
    emit({ releaseId: 'a', mandatory: false });

    expect(removed).not.toHaveBeenCalled();
    expect(kept).toHaveBeenCalledTimes(1);
  });
});
