import { NextFunction, Request, Response, Router } from 'express';
import { z } from 'zod';
import { AnalysisManager } from '../services/analysisManager';
import { ValidationError } from '../utils/errors';

const SubmitAnalysisBodySchema = z
  .object({
    repositoryUrl: z.unknown(),
  })
  .strict();

function asyncHandler(
  fn: (req: Request, res: Response, next: NextFunction) => Promise<void>,
): (req: Request, res: Response, next: NextFunction) => void {
  return (req, res, next) => {
    void fn(req, res, next).catch(next);
  };
}

export function createAnalysesRouter(manager: AnalysisManager): Router {
  const router = Router();

  router.post(
    '/analyses',
    asyncHandler(async (req, res) => {
      if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body)) {
        throw new ValidationError('Request body must be a JSON object containing repositoryUrl');
      }

      const parsed = SubmitAnalysisBodySchema.safeParse(req.body);
      if (!parsed.success || !Object.hasOwn(req.body, 'repositoryUrl')) {
        throw new ValidationError(
          'Request body must include strictly { "repositoryUrl": "https://github.com/owner/repo" }',
          parsed.success ? undefined : parsed.error.issues,
        );
      }

      const accepted = await manager.submitAnalysis(parsed.data.repositoryUrl);
      res.status(202).json(accepted);
    }),
  );

  router.get('/analyses/:id', (req, res) => {
    const id = req.params['id'] ?? '';
    const status = manager.getPublicStatus(id);
    res.status(200).json(status);
  });

  router.get('/analyses/:id/results', (req, res) => {
    const id = req.params['id'] ?? '';
    const results = manager.getPublicResults(id);
    res.status(200).json(results);
  });

  router.get(
    '/analyses/:id/charts/:name',
    asyncHandler(async (req, res) => {
      const id = req.params['id'] ?? '';
      const name = req.params['name'] ?? '';
      const pngBuffer = await manager.getChartArtifact(id, name);

      res.status(200);
      res.setHeader('Content-Type', 'image/png');
      res.setHeader('Cache-Control', 'private, max-age=300');
      res.send(pngBuffer);
    }),
  );

  return router;
}
