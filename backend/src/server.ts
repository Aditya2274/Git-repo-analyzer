import { createApp } from './app';
import { loadConfig } from './config/env';
import { FileAnalysisStore } from './services/analysisStore';

async function main(): Promise<void> {
  const config = loadConfig(process.env);
  const store = new FileAnalysisStore(config.dataDir);

  const recovery = await store.initialize({
    maxInFlightAgeMs: config.analysisTimeoutMs,
    failAllInFlightOnRestart: false,
  });

  const app = createApp({ config, store });

  const server = app.listen(config.port, config.host, () => {
    console.log(
      JSON.stringify({
        event: 'backend_started',
        env: config.nodeEnv,
        host: config.host,
        port: config.port,
        dataDir: config.dataDir,
        jenkinsMockMode: config.jenkins.mockMode,
        recovery,
      }),
    );
  });

  const shutdown = (signal: string) => {
    console.log(JSON.stringify({ event: 'backend_shutting_down', signal }));
    server.close((closeErr) => {
      if (closeErr) {
        console.error(JSON.stringify({ event: 'shutdown_error', error: closeErr.message }));
        process.exit(1);
      }
      process.exit(0);
    });
  };

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main().catch((err) => {
  console.error(
    JSON.stringify({
      event: 'backend_startup_failed',
      error: err instanceof Error ? err.message : String(err),
    }),
  );
  process.exit(1);
});
