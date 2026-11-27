import { createApp } from './app';
import { loadConfig } from './config/env';
import { AnalysisManager } from './services/analysisManager';
import { FileAnalysisStore } from './services/analysisStore';
import { ArtifactIngestor } from './services/artifactIngestion';
import { IJenkinsClient } from './services/jenkinsClient';
import { LiveJenkinsClient } from './services/liveJenkinsClient';
import { MockJenkinsClient } from './services/mockJenkinsClient';

async function main(): Promise<void> {
  const config = loadConfig(process.env);
  const store = new FileAnalysisStore(config.dataDir);
  const artifactIngestor = new ArtifactIngestor(config.dataDir);

  const recovery = await store.initialize({
    maxInFlightAgeMs: config.analysisTimeoutMs,
    failAllInFlightOnRestart: false,
  });

  const jenkinsClient: IJenkinsClient = config.jenkins.mockMode
    ? new MockJenkinsClient()
    : new LiveJenkinsClient({
        baseUrl: config.jenkins.url!,
        username: config.jenkins.user!,
        apiToken: config.jenkins.apiToken!,
        jobName: config.jenkins.jobName,
        requestTimeoutMs: config.jenkins.requestTimeoutMs,
      });

  const analysisManager = new AnalysisManager({
    store,
    artifactIngestor,
    jenkinsClient,
    ssrfCheckDns: config.ssrfCheckDns,
    analysisTimeoutMs: config.analysisTimeoutMs,
    pollIntervalMs: config.pollIntervalMs,
  });

  const resumedCount = analysisManager.resumePendingAnalyses();
  const app = createApp({ config, store, analysisManager });

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
        resumedInFlightCount: resumedCount,
      }),
    );
  });

  const shutdown = (signal: string) => {
    console.log(JSON.stringify({ event: 'backend_shutting_down', signal }));
    void analysisManager.stop().finally(() => {
      server.close((closeErr) => {
        if (closeErr) {
          console.error(JSON.stringify({ event: 'shutdown_error', error: closeErr.message }));
          process.exit(1);
        }
        process.exit(0);
      });
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
