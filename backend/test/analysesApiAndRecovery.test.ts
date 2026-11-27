import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fsPromises from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { createApp } from '../src/app';
import { loadConfig } from '../src/config/env';
import { AnalysisManager } from '../src/services/analysisManager';
import { FileAnalysisStore } from '../src/services/analysisStore';
import { ArtifactIngestor } from '../src/services/artifactIngestion';
import { MockJenkinsClient, MockScenario } from '../src/services/mockJenkinsClient';
import { validateRepositoryUrlWithSsrfGuard } from '../src/validators/repoValidator';

async function createTestContext(
  dataDir: string,
  options: {
    scenarioResolver?: (url: string) => MockScenario;
    queueDelayMs?: number;
    buildDelayMs?: number;
    pollIntervalMs?: number;
    dnsAddress?: string;
  } = {},
) {
  const store = new FileAnalysisStore(dataDir);
  await store.initialize();

  const artifactIngestor = new ArtifactIngestor(dataDir);
  const jenkinsClient = new MockJenkinsClient({
    queueDelayMs: options.queueDelayMs ?? 30,
    buildDelayMs: options.buildDelayMs ?? 30,
    ...(options.scenarioResolver ? { scenarioResolver: options.scenarioResolver } : {}),
  });

  const dnsIp = options.dnsAddress ?? '140.82.121.3';
  const analysisManager = new AnalysisManager({
    store,
    artifactIngestor,
    jenkinsClient,
    ssrfCheckDns: true,
    analysisTimeoutMs: 600_000,
    pollIntervalMs: options.pollIntervalMs ?? 20,
    validateRepository: (input, opts) =>
      validateRepositoryUrlWithSsrfGuard(input, {
        ...opts,
        dnsLookup: async () => [{ address: dnsIp, family: 4 }],
      }),
  });

  const config = loadConfig({
    NODE_ENV: 'test',
    DATA_DIR: dataDir,
    JENKINS_MOCK_MODE: 'true',
  });
  const app = createApp({ config, store, analysisManager });
  const server = http.createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Unexpected server address');
  }

  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    store,
    artifactIngestor,
    jenkinsClient,
    analysisManager,
    close: async () => {
      await analysisManager.stop();
      await new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
    },
  };
}

async function waitForTerminalStatus(baseUrl: string, analysisId: string): Promise<{ status: string; body: Record<string, unknown> }> {
  for (let i = 0; i < 60; i += 1) {
    const res = await fetch(`${baseUrl}/api/analyses/${analysisId}`);
    const body = (await res.json()) as Record<string, unknown>;
    if (body['status'] === 'COMPLETED' || body['status'] === 'FAILED' || body['status'] === 'CANCELLED') {
      return { status: String(body['status']), body };
    }
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`Timed out waiting for analysis ${analysisId}`);
}

test('Analyses API executes complete submission, polling, results, and PNG chart serving without leaking Jenkins details', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'api-e2e-'));
  const ctx = await createTestContext(dataDir, { queueDelayMs: 60, buildDelayMs: 60, pollIntervalMs: 25 });
  try {
    // 1. Submit valid repository
    const postRes = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'https://github.com/octocat/Hello-World' }),
    });
    assert.equal(postRes.status, 202);
    const accepted = (await postRes.json()) as Record<string, unknown>;
    assert.equal(accepted['status'], 'QUEUED');
    assert.equal(typeof accepted['analysisId'], 'string');
    assert.equal(typeof accepted['createdAt'], 'string');
    assert.equal('queueId' in accepted, false);
    assert.equal('buildNumber' in accepted, false);

    const analysisId = String(accepted['analysisId']);

    // 2. While QUEUED/BUILDING, status returns metadata and results/charts return 409 CONFLICT
    const statusRes = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}`);
    assert.equal(statusRes.status, 200);
    const statusBody = (await statusRes.json()) as Record<string, unknown>;
    assert.equal('queueId' in statusBody, false);
    assert.equal('buildNumber' in statusBody, false);
    assert.equal('repositoryUrl' in statusBody, false);

    const earlyResults = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/results`);
    assert.equal(earlyResults.status, 409);
    const earlyErr = (await earlyResults.json()) as { error: { code: string } };
    assert.equal(earlyErr.error.code, 'CONFLICT');

    const earlyChart = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/charts/commits_per_author.png`);
    assert.equal(earlyChart.status, 409);

    // 3. Wait for COMPLETED
    const finalState = await waitForTerminalStatus(ctx.baseUrl, analysisId);
    assert.equal(finalState.status, 'COMPLETED');

    const resultsRes = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/results`);
    assert.equal(resultsRes.status, 200);
    const resultsBody = (await resultsRes.json()) as Record<string, unknown>;
    assert.equal(resultsBody['analysisId'], analysisId);
    assert.equal(resultsBody['status'], 'COMPLETED');
    assert.equal('queueId' in resultsBody, false);
    assert.equal('buildNumber' in resultsBody, false);
    assert.ok(!JSON.stringify(resultsBody).includes(dataDir), 'Must never expose internal filesystem paths');

    // 4. Serve cached PNG charts cleanly
    for (const chartName of ['commits_per_author.png', 'daily_commit_activity.png']) {
      const chartRes = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/charts/${chartName}`);
      assert.equal(chartRes.status, 200);
      assert.equal(chartRes.headers.get('content-type'), 'image/png');
      const pngBytes = Buffer.from(await chartRes.arrayBuffer());
      assert.deepEqual(pngBytes.subarray(0, 4), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    }

    // 5. Invalid chart names & traversal rejected
    const badChart = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/charts/arbitrary.png`);
    assert.equal(badChart.status, 400);

    const encodedTraversal = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/charts/%2e%2e%2fanalyses.json`);
    assert.equal(encodedTraversal.status, 400);

    const rawTraversal = await fetch(`${ctx.baseUrl}/api/analyses/${analysisId}/charts/../../etc/passwd`);
    assert.equal(rawTraversal.status, 404);
  } finally {
    await ctx.close();
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});

test('Analyses API rejects invalid inputs, handles failed dispatches cleanly, and handles failed/incomplete builds explicitly', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'api-errors-'));
  const scenarioMap: Record<string, MockScenario> = {
    'https://github.com/octocat/Dispatch-Down': 'dispatch_error',
    'https://github.com/octocat/Build-Fail': 'fail',
    'https://github.com/octocat/Incomplete-Build': 'missing_chart',
    'https://github.com/octocat/Empty-Repo': 'zero_commits',
  };

  const ctx = await createTestContext(dataDir, {
    queueDelayMs: 15,
    buildDelayMs: 15,
    pollIntervalMs: 15,
    scenarioResolver: (url) => scenarioMap[url] ?? 'success',
  });

  try {
    // 1. Validation & body checks
    const invalidBody = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url: 'https://github.com/octocat/Hello-World' }),
    });
    assert.equal(invalidBody.status, 400);

    const ssrfUrl = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'http://169.254.169.254/latest/meta-data/' }),
    });
    assert.equal(ssrfUrl.status, 400);

    // Unknown ID & bad UUID
    const badId = await fetch(`${ctx.baseUrl}/api/analyses/not-a-uuid`);
    assert.equal(badId.status, 400);
    const missingId = await fetch(`${ctx.baseUrl}/api/analyses/${randomUUID()}`);
    assert.equal(missingId.status, 404);
    const missingResults = await fetch(`${ctx.baseUrl}/api/analyses/${randomUUID()}/results`);
    assert.equal(missingResults.status, 404);

    // 2. Dispatch failure returns 503 AND transitions persisted record away from QUEUED -> FAILED
    const dispatchFail = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'https://github.com/octocat/Dispatch-Down' }),
    });
    assert.equal(dispatchFail.status, 503);
    const dfJson = (await dispatchFail.json()) as { error: { code: string; details: { analysisId: string } } };
    assert.equal(dfJson.error.code, 'SERVICE_UNAVAILABLE');
    const persistedFail = ctx.store.getById(dfJson.error.details.analysisId);
    assert.equal(persistedFail?.status, 'FAILED');
    assert.equal(persistedFail?.error?.code, 'DISPATCH_FAILED');

    // 3. Build failure stops as FAILED and rejects results
    const buildFailRes = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'https://github.com/octocat/Build-Fail' }),
    });
    assert.equal(buildFailRes.status, 202);
    const bfAccepted = (await buildFailRes.json()) as { analysisId: string };
    const bfFinal = await waitForTerminalStatus(ctx.baseUrl, bfAccepted.analysisId);
    assert.equal(bfFinal.status, 'FAILED');
    const bfResults = await fetch(`${ctx.baseUrl}/api/analyses/${bfAccepted.analysisId}/results`);
    assert.equal(bfResults.status, 409);

    // 4. Missing required chart rejects ingestion explicitly (FAILED, never silent COMPLETED)
    const missingChartRes = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'https://github.com/octocat/Incomplete-Build' }),
    });
    assert.equal(missingChartRes.status, 202);
    const mcAccepted = (await missingChartRes.json()) as { analysisId: string };
    const mcFinal = await waitForTerminalStatus(ctx.baseUrl, mcAccepted.analysisId);
    assert.equal(mcFinal.status, 'FAILED');
    assert.equal((mcFinal.body['error'] as { code: string }).code, 'ARTIFACT_INGESTION_FAILED');

    // 5. Zero-commit repo completes cleanly and returns 404 for omitted PNG chart
    const zeroRes = await fetch(`${ctx.baseUrl}/api/analyses`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repositoryUrl: 'https://github.com/octocat/Empty-Repo' }),
    });
    assert.equal(zeroRes.status, 202);
    const zeroAccepted = (await zeroRes.json()) as { analysisId: string };
    const zeroFinal = await waitForTerminalStatus(ctx.baseUrl, zeroAccepted.analysisId);
    assert.equal(zeroFinal.status, 'COMPLETED');
    const zeroChart = await fetch(`${ctx.baseUrl}/api/analyses/${zeroAccepted.analysisId}/charts/commits_per_author.png`);
    assert.equal(zeroChart.status, 404);
  } finally {
    await ctx.close();
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});

test('AnalysisManager resumes in-flight Jenkins jobs across restart WITHOUT calling triggerJob again', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'api-recovery-'));
  try {
    const sharedMock = new MockJenkinsClient({ queueDelayMs: 0, buildDelayMs: 0 });
    const dispatched = await sharedMock.triggerJob('https://github.com/octocat/Hello-World');

    // Pre-seed store representing state persisted just before backend restart
    const store1 = new FileAnalysisStore(dataDir);
    await store1.initialize();
    const inFlightId = randomUUID();
    const undispatchedId = randomUUID();
    const completedId = randomUUID();
    const nowIso = new Date().toISOString();

    await store1.save({
      analysisId: inFlightId,
      repositoryUrl: 'https://github.com/octocat/Hello-World',
      status: 'QUEUED',
      progress: 'Queued before restart',
      createdAt: nowIso,
      updatedAt: nowIso,
      error: null,
      queueId: dispatched.queueId,
      buildNumber: null,
      results: null,
    });
    await store1.save({
      analysisId: undispatchedId,
      repositoryUrl: 'https://github.com/octocat/Hello-World',
      status: 'QUEUED',
      progress: 'Interrupted before queueId',
      createdAt: nowIso,
      updatedAt: nowIso,
      error: null,
      queueId: null,
      buildNumber: null,
      results: null,
    });
    await store1.save({
      analysisId: completedId,
      repositoryUrl: 'https://github.com/octocat/Finished',
      status: 'COMPLETED',
      progress: 'Analysis completed',
      createdAt: nowIso,
      updatedAt: nowIso,
      error: null,
      queueId: 1,
      buildNumber: 1,
      results: { metrics: { ok: true }, summaryMarkdown: '# Done', charts: { commitsPerAuthor: null, dailyActivity: null } },
    });

    // Simulate restart with fresh FileAnalysisStore + spying triggerJob call count
    let triggerCount = 0;
    const spyingClient: MockJenkinsClient = Object.assign(Object.create(Object.getPrototypeOf(sharedMock)), sharedMock);
    spyingClient.triggerJob = async (url: string) => {
      triggerCount += 1;
      return sharedMock.triggerJob(url);
    };

    const store2 = new FileAnalysisStore(dataDir);
    await store2.initialize({ maxInFlightAgeMs: 600_000 });
    const ingestor2 = new ArtifactIngestor(dataDir);
    const manager2 = new AnalysisManager({
      store: store2,
      artifactIngestor: ingestor2,
      jenkinsClient: spyingClient,
      ssrfCheckDns: true,
      analysisTimeoutMs: 600_000,
      pollIntervalMs: 15,
    });

    const resumed = manager2.resumePendingAnalyses();
    assert.equal(resumed, 1, 'Only valid in-flight job with queueId should resume polling');
    assert.equal(triggerCount, 0, 'Recovery must NEVER re-trigger triggerJob');

    assert.equal(manager2.getPublicStatus(undispatchedId).status, 'FAILED');
    assert.equal(manager2.getPublicStatus(completedId).status, 'COMPLETED');

    // Step/wait until resumed in-flight job resolves queue -> builds -> completes
    for (let i = 0; i < 40; i += 1) {
      if (manager2.getPublicStatus(inFlightId).status === 'COMPLETED') {
        break;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    assert.equal(manager2.getPublicStatus(inFlightId).status, 'COMPLETED');
    assert.equal(triggerCount, 0, 'Still zero duplicate triggerJob calls after recovery completion');

    await manager2.stop();
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});
