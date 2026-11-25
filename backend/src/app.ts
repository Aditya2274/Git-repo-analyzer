import cors from 'cors';
import express, { Express, NextFunction, Request, Response } from 'express';
import { AppConfig } from './config/env';
import { createAnalysesRouter } from './routes/analyses';
import { createHealthRouter } from './routes/health';
import { AnalysisManager } from './services/analysisManager';
import { FileAnalysisStore } from './services/analysisStore';
import { AppError, CorsForbiddenError, NotFoundError, formatErrorResponse } from './utils/errors';

export interface AppDependencies {
  config: AppConfig;
  store: FileAnalysisStore;
  analysisManager?: AnalysisManager;
}

/**
 * Creates the Express application with centralized security headers, strict CORS
 * origin validation, canonical API endpoints, and standard JSON error handling.
 */
export function createApp({ config, store, analysisManager }: AppDependencies): Express {
  const app = express();

  app.disable('x-powered-by');
  app.set('trust proxy', 1);

  app.use((_req: Request, res: Response, next: NextFunction) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    next();
  });

  const allowedOrigins = new Set(config.corsOrigins);
  app.use(
    cors({
      origin: (origin, callback) => {
        // Same-origin / NGINX proxy / server-side health checks omit Origin header;
        // explicit empty Origin: "" is rejected rather than treated as omitted.
        if (origin === undefined) {
          callback(null, true);
          return;
        }
        if (allowedOrigins.has(origin)) {
          callback(null, true);
          return;
        }
        callback(new CorsForbiddenError(`Origin "${origin}" is not permitted by CORS policy`));
      },
      methods: ['GET', 'POST', 'OPTIONS'],
      allowedHeaders: ['Content-Type'],
    }),
  );

  app.use(express.json({ limit: '64kb' }));

  app.use('/api', createHealthRouter(store));
  if (analysisManager) {
    app.use('/api', createAnalysesRouter(analysisManager));
  }

  app.use((req: Request, _res: Response, next: NextFunction) => {
    next(new NotFoundError(`Route ${req.method} ${req.originalUrl} was not found`));
  });

  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof AppError) {
      res.status(err.statusCode).json(formatErrorResponse(err.code, err.message, err.details));
      return;
    }

    if (
      err instanceof SyntaxError &&
      'status' in err &&
      (err as { status?: number }).status === 400 &&
      'body' in err
    ) {
      res
        .status(400)
        .json(formatErrorResponse('INVALID_JSON', 'Request body contains malformed JSON'));
      return;
    }

    const message =
      config.nodeEnv === 'production'
        ? 'An unexpected internal error occurred'
        : err instanceof Error
          ? err.message
          : 'An unexpected internal error occurred';

    res.status(500).json(formatErrorResponse('INTERNAL_ERROR', message));
  });

  return app;
}
