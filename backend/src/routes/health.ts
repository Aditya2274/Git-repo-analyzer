import { Request, Response, Router } from 'express';
import { FileAnalysisStore } from '../services/analysisStore';
import { formatErrorResponse } from '../utils/errors';

export function createHealthRouter(store: FileAnalysisStore): Router {
  const router = Router();

  router.get('/health', (_req: Request, res: Response) => {
    if (!store.isInitialized()) {
      res
        .status(503)
        .json(formatErrorResponse('SERVICE_UNAVAILABLE', 'Analysis persistence store is not initialized'));
      return;
    }

    res.status(200).json({
      status: 'UP',
      timestamp: new Date().toISOString(),
    });
  });

  return router;
}
