import fs from 'node:fs';
import path from 'node:path';
import { Request, Response, Router } from 'express';
import { FileAnalysisStore } from '../services/analysisStore';
import { formatErrorResponse } from '../utils/errors';

const RELEASE_ID_REGEX = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

/**
 * Resolves the running backend release identifier once at process startup from
 * the immutable release-manifest.json bundled beside this release directory.
 * Returns null in development/unit-test environments without a release wrapper.
 */
export function resolveRuntimeReleaseId(overrideManifestPath?: string): string | null {
  const candidates = overrideManifestPath
    ? [overrideManifestPath]
    : [
        path.resolve(__dirname, '..', '..', '..', 'release-manifest.json'),
        path.resolve(__dirname, '..', '..', 'release-manifest.json'),
      ];

  for (const candidate of candidates) {
    try {
      if (!overrideManifestPath) {
        const releaseDir = path.dirname(candidate);
        if (!fs.existsSync(path.join(releaseDir, 'backend', 'dist', 'server.js'))) {
          continue;
        }
      }
      const stat = fs.lstatSync(candidate);
      if (!stat.isFile() || stat.isSymbolicLink()) {
        continue;
      }
      const parsed = JSON.parse(fs.readFileSync(candidate, 'utf8')) as { releaseId?: unknown };
      if (
        typeof parsed.releaseId === 'string' &&
        RELEASE_ID_REGEX.test(parsed.releaseId) &&
        !parsed.releaseId.includes('..')
      ) {
        return parsed.releaseId;
      }
    } catch {
      // Ignore missing or unreadable release metadata outside packaged releases.
    }
  }

  return null;
}

export function createHealthRouter(
  store: FileAnalysisStore,
  runtimeReleaseId: string | null = resolveRuntimeReleaseId(),
): Router {
  const router = Router();

  router.get('/health', (_req: Request, res: Response) => {
    if (runtimeReleaseId !== null) {
      res.setHeader('X-App-Release', runtimeReleaseId);
    }

    if (!store.isInitialized()) {
      res
        .status(503)
        .json(formatErrorResponse('SERVICE_UNAVAILABLE', 'Analysis persistence store is not initialized'));
      return;
    }

    const payload: { status: 'UP'; timestamp: string; releaseId?: string } = {
      status: 'UP',
      timestamp: new Date().toISOString(),
    };
    if (runtimeReleaseId !== null) {
      payload.releaseId = runtimeReleaseId;
    }

    res.status(200).json(payload);
  });

  return router;
}
