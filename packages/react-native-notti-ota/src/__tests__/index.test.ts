import { describe, expect, it, jest } from '@jest/globals';

jest.mock('../NativeNottiOta', () => ({
  __esModule: true,
  default: {
    getCurrentRelease: jest.fn(async () => ({
      releaseId: null,
      isEmbedded: true,
    })),
  },
}));

import { getCurrentRelease } from '../index';

describe('getCurrentRelease', () => {
  it('returns what the native module reports', async () => {
    await expect(getCurrentRelease()).resolves.toEqual({
      releaseId: null,
      isEmbedded: true,
    });
  });
});
