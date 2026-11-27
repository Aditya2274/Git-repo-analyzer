import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
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
import { LiveJenkinsClient } from '../src/services/liveJenkinsClient';
import {
  buildSampleMarkdown,
  buildSampleMetrics,
  createSamplePngBuffer,
} from '../src/services/mockJenkinsClient';
import { validateRepositoryUrlWithSsrfGuard } from '../src/validators/repoValidator';

interface EphemeralCreds {
  username: string;
  apiToken: string;
  expectedAuthHeader: string;
  crumbField: string;
  crumbValue: string;
}

function generateEphemeralCreds(crumbField = 'Jenkins-Crumb'): EphemeralCreds {
  const username = `proto-user-${randomUUID().slice(0, 8)}`;
  const apiToken = randomBytes(24).toString('hex');
  const encoded = Buffer.from(`${username}:${apiToken}`, 'utf8').toString('base64');
  return {
    username,
    apiToken,
    expectedAuthHeader: `Basic ${encoded}`,
    crumbField,
    crumbValue: `crumb-${randomBytes(12).toString('hex')}`,
  };
}

async function startHttpServer(
  handler: http.RequestListener,
): Promise<{ origin: string; close: () => Promise<void> }> {
  const server = http.createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Expected ephemeral TCP port');
  }
  return {
    origin: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.closeAllConnections?.();
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

interface BackendHarness {
  baseUrl: string;
  dataDir: string;
  store: FileAnalysisStore;
  artifactIngestor: ArtifactIngestor;
  analysisManager: AnalysisManager;
  close: () => Promise<void>;
}

async function startBackendHarness(options: {
  jenkinsOrigin: string;
  creds: EphemeralCreds;
  jobName?: string;
  requestTimeoutMs?: number;
  maxArtifactBytes?: number;
  pollIntervalMs?: number;
  analysisTimeoutMs?: number;
}): Promise<BackendHarness> {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'proto-73-'));
  const store = new FileAnalysisStore(dataDir);
  await store.initialize();

  const artifactIngestor = new ArtifactIngestor(dataDir);
  const jenkinsClient = new LiveJenkinsClient({
    baseUrl: options.jenkinsOrigin,
    username: options.creds.username,
    apiToken: options.creds.apiToken,
    jobName: options.jobName ?? 'git-repo-analyzer',
    requestTimeoutMs: options.requestTimeoutMs ?? 1500,
    ...(options.maxArtifactBytes !== undefined ? { maxArtifactBytes: options.maxArtifactBytes } : {}),
  });

  const analysisManager = new AnalysisManager({
    store,
    artifactIngestor,
    jenkinsClient,
    ssrfCheckDns: true,
    analysisTimeoutMs: options.analysisTimeoutMs ?? 60_000,
    pollIntervalMs: options.pollIntervalMs ?? 15,
    validateRepository: (input, opts) =>
      validateRepositoryUrlWithSsrfGuard(input, {
        ...opts,
        dnsLookup: async () => [{ address: '140.82.121.3', family: 4 }],
      }),
  });

  const config = loadConfig({
    NODE_ENV: 'test',
    DATA_DIR: dataDir,
    JENKINS_MOCK_MODE: 'false',
    JENKINS_URL: options.jenkinsOrigin,
    JENKINS_USER: options.creds.username,
    JENKINS_API_TOKEN: options.creds.apiToken,
    JENKINS_JOB_NAME: options.jobName ?? 'git-repo-analyzer',
    JENKINS_REQUEST_TIMEOUT_MS: String(options.requestTimeoutMs ?? 1500),
  });

  const app = createApp({ config, store, analysisManager });
  const server = http.createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Unexpected backend listen address');
  }

  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    dataDir,
    store,
    artifactIngestor,
    analysisManager,
    close: async () => {
      await analysisManager.stop();
      await new Promise<void>((resolve, reject) => {
        server.closeAllConnections?.();
        server.close((err) => (err ? reject(err) : resolve()));
      });
      await fsPromises.rm(dataDir, { recursive: true, force: true });
    },
  };
}

async function readRequestBody(req: http.IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function submitAnalysis(
  baseUrl: string,
  repositoryUrl: unknown,
): Promise<{ status: number; bodyText: string; json: Record<string, unknown> }> {
  const res = await fetch(`${baseUrl}/api/analyses`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ repositoryUrl }),
  });
  const bodyText = await res.text();
  return {
    status: res.status,
    bodyText,
    json: JSON.parse(bodyText) as Record<string, unknown>,
  };
}

async function waitForStatus(
  baseUrl: string,
  analysisId: string,
  predicate: (body: Record<string, unknown>) => boolean,
): Promise<Record<string, unknown>> {
  for (let i = 0; i < 120; i += 1) {
    const res = await fetch(`${baseUrl}/api/analyses/${analysisId}`);
    assert.equal(res.status, 200);
    const body = (await res.json()) as Record<string, unknown>;
    if (predicate(body)) {
      return body;
    }
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error(`Timed out waiting for status condition on ${analysisId}`);
}

function assertNoSensitiveOrInternalLeak(rawText: string, creds: EphemeralCreds, jenkinsOrigin?: string): void {
  assert.equal(rawText.includes(creds.apiToken), false, 'Leaked Jenkins API token');
  assert.equal(rawText.includes(creds.expectedAuthHeader), false, 'Leaked Basic Auth header');
  assert.equal(rawText.includes(creds.crumbValue), false, 'Leaked CSRF crumb');
  assert.equal(rawText.includes('"queueId"'), false, 'Leaked internal queueId');
  assert.equal(rawText.includes('"buildNumber"'), false, 'Leaked internal buildNumber');
  if (jenkinsOrigin) {
    assert.equal(rawText.includes(jenkinsOrigin), false, 'Leaked internal Jenkins controller origin');
  }
}

test('Phase 7.3 [Dispatch & Lifecycle]: Backend dispatches REPO_URL with Basic Auth + DefaultCrumbIssuer CSRF across 201/302 queues and active/zero-commit builds', async () => {
  const creds = generateEphemeralCreds('Jenkins-Crumb');
  const samplePng = createSamplePngBuffer();

  interface DispatchRecord {
    method: string;
    url: string;
    contentType: string | undefined;
    crumb: string | undefined;
    params: Record<string, string>;
  }
  const dispatches: DispatchRecord[] = [];
  const queuePolls = new Map<number, number>();
  const buildPolls = new Map<number, number>();
  let nextQueueId = 100;
  let nextBuildNumber = 40;
  const queueToBuild = new Map<number, { buildNumber: number; repoUrl: string }>();
  const buildToRepo = new Map<number, string>();
  let allowActiveQueueResolve = false;
  let allowActiveBuildComplete = false;
  let activeQueuePolledCount = 0;
  let activeBuildPolledWhileBuildingCount = 0;
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer(async (req, res) => {
    if (req.headers.authorization !== creds.expectedAuthHeader) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Jenkins"' }).end('Unauthorized');
      return;
    }

    const reqUrl = req.url ?? '/';

    if (reqUrl === '/crumbIssuer/api/json' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          _class: 'hudson.security.csrf.DefaultCrumbIssuer',
          crumbRequestField: creds.crumbField,
          crumb: creds.crumbValue,
        }),
      );
      return;
    }

    if (reqUrl === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      const incomingCrumb = req.headers[creds.crumbField.toLowerCase()];
      if (incomingCrumb !== creds.crumbValue) {
        res.writeHead(403).end('No valid crumb was included in the request');
        return;
      }

      const body = await readRequestBody(req);
      const parsed = new URLSearchParams(body);
      const paramEntries = Object.fromEntries(parsed.entries());
      dispatches.push({
        method: req.method,
        url: reqUrl,
        contentType: req.headers['content-type'],
        crumb: typeof incomingCrumb === 'string' ? incomingCrumb : undefined,
        params: paramEntries,
      });

      const repoUrl = paramEntries['REPO_URL'] ?? '';
      nextQueueId += 1;
      nextBuildNumber += 1;
      const queueId = nextQueueId;
      queueToBuild.set(queueId, { buildNumber: nextBuildNumber, repoUrl });
      buildToRepo.set(nextBuildNumber, repoUrl);

      if (repoUrl.includes('Empty-Repo')) {
        // Classic 302 form-POST Location redirect (relative path)
        res.writeHead(302, { Location: `/queue/item/${queueId}/` }).end();
      } else {
        // Modern 201 Created with absolute queue item URL
        res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/${queueId}/` }).end();
      }
      return;
    }

    const qMatch = reqUrl.match(/^\/queue\/item\/(\d+)\/api\/json$/);
    if (qMatch && req.method === 'GET') {
      const queueId = Number(qMatch[1]);
      const entry = queueToBuild.get(queueId);
      if (!entry) {
        res.writeHead(404).end();
        return;
      }
      const count = (queuePolls.get(queueId) ?? 0) + 1;
      queuePolls.set(queueId, count);

      const isActiveRepo = !entry.repoUrl.includes('Empty-Repo');
      if (isActiveRepo) {
        activeQueuePolledCount += 1;
      }
      if (isActiveRepo ? !allowActiveQueueResolve : count === 1) {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({ cancelled: false, executable: null }),
        );
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({
            cancelled: false,
            executable: {
              number: entry.buildNumber,
              url: `${jenkinsOrigin}/job/git-repo-analyzer/${entry.buildNumber}/`,
            },
          }),
        );
      }
      return;
    }

    const bMatch = reqUrl.match(/^\/job\/git-repo-analyzer\/(\d+)\/api\/json$/);
    if (bMatch && req.method === 'GET') {
      const buildNumber = Number(bMatch[1]);
      const repoUrl = buildToRepo.get(buildNumber);
      if (!repoUrl) {
        res.writeHead(404).end();
        return;
      }
      const count = (buildPolls.get(buildNumber) ?? 0) + 1;
      buildPolls.set(buildNumber, count);

      const isZero = repoUrl.includes('Empty-Repo');
      if (!isZero ? !allowActiveBuildComplete : count === 1) {
        if (!isZero) {
          activeBuildPolledWhileBuildingCount += 1;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({ building: true, result: null, duration: 0, artifacts: [] }),
        );
        return;
      }

      const artifacts = [
        { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
        { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
        { fileName: 'build-meta.txt', relativePath: 'target-repo/reports/build-meta.txt' },
        ...(!isZero
          ? [
              { fileName: 'commits_per_author.png', relativePath: 'target-repo/reports/charts/commits_per_author.png' },
              { fileName: 'daily_commit_activity.png', relativePath: 'target-repo/reports/charts/daily_commit_activity.png' },
            ]
          : []),
      ];
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          building: false,
          result: 'SUCCESS',
          duration: 3150,
          url: `${jenkinsOrigin}/job/git-repo-analyzer/${buildNumber}/`,
          artifacts,
        }),
      );
      return;
    }

    const aMatch = reqUrl.match(/^\/job\/git-repo-analyzer\/(\d+)\/artifact\/(.+)$/);
    if (aMatch && req.method === 'GET') {
      const buildNumber = Number(aMatch[1]);
      const relPath = decodeURIComponent(aMatch[2] ?? '');
      const repoUrl = buildToRepo.get(buildNumber) ?? 'https://github.com/octocat/Hello-World';
      const isZero = repoUrl.includes('Empty-Repo');

      if (relPath === 'target-repo/reports/metrics.json') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify(buildSampleMetrics(repoUrl, isZero)),
        );
        return;
      }
      if (relPath === 'target-repo/reports/summary.md') {
        res.writeHead(200, { 'Content-Type': 'text/markdown' }).end(
          buildSampleMarkdown(repoUrl, isZero),
        );
        return;
      }
      if (
        !isZero &&
        (relPath === 'target-repo/reports/charts/commits_per_author.png' ||
          relPath === 'target-repo/reports/charts/daily_commit_activity.png')
      ) {
        res.writeHead(200, { 'Content-Type': 'image/png' }).end(samplePng);
        return;
      }
    }

    res.writeHead(404).end('Not found');
  });
  jenkinsOrigin = jenkinsServer.origin;

  const backend = await startBackendHarness({
    jenkinsOrigin,
    creds,
    pollIntervalMs: 15,
  });

  try {
    // 1. Active repository flow (HTTP 201 Created Location) with deterministic lifecycle gates
    const activeSubmit = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(activeSubmit.status, 202);
    assert.equal(activeSubmit.json['status'], 'QUEUED');
    assertNoSensitiveOrInternalLeak(activeSubmit.bodyText, creds, jenkinsOrigin);

    const activeId = String(activeSubmit.json['analysisId']);
    assert.equal(dispatches.length, 1);
    assert.equal(dispatches[0]?.contentType, 'application/x-www-form-urlencoded');
    assert.equal(dispatches[0]?.crumb, creds.crumbValue);
    assert.deepEqual(dispatches[0]?.params, { REPO_URL: 'https://github.com/octocat/Hello-World' });

    // Confirm results & charts stay blocked (409) deterministically while latched in QUEUED
    for (let i = 0; i < 40 && activeQueuePolledCount === 0; i += 1) {
      await new Promise((r) => setTimeout(r, 10));
    }
    assert.ok(activeQueuePolledCount >= 1, 'Expected live queue poll before releasing queue gate');
    const preCompleteStatus = await (await fetch(`${backend.baseUrl}/api/analyses/${activeId}`)).json() as Record<string, unknown>;
    assert.equal(preCompleteStatus['status'], 'QUEUED');
    const preCompleteResults = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/results`);
    assert.equal(preCompleteResults.status, 409);
    const preCompleteChart = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/charts/commits_per_author.png`);
    assert.equal(preCompleteChart.status, 409);

    // Release queue gate so Jenkins resolves buildNumber and transitions backend deterministically to BUILDING
    allowActiveQueueResolve = true;
    const buildingStatus = await waitForStatus(backend.baseUrl, activeId, (b) => b['status'] === 'BUILDING');
    assert.equal(buildingStatus['progress'], 'Analyzing commits, metrics, charts, and insights...');
    assertNoSensitiveOrInternalLeak(JSON.stringify(buildingStatus), creds, jenkinsOrigin);

    // While latched in BUILDING (controller still returns building: true), verify repeated poll + 409 gates
    for (let i = 0; i < 40 && activeBuildPolledWhileBuildingCount === 0; i += 1) {
      await new Promise((r) => setTimeout(r, 10));
    }
    assert.ok(activeBuildPolledWhileBuildingCount >= 1, 'Expected live build poll while latched in BUILDING');
    const duringBuildResults = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/results`);
    assert.equal(duringBuildResults.status, 409);
    const duringBuildChart = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/charts/commits_per_author.png`);
    assert.equal(duringBuildChart.status, 409);

    // Release build completion gate and await COMPLETED
    allowActiveBuildComplete = true;
    const completedStatus = await waitForStatus(backend.baseUrl, activeId, (b) => b['status'] === 'COMPLETED');
    assertNoSensitiveOrInternalLeak(JSON.stringify(completedStatus), creds, jenkinsOrigin);

    const resultsRes = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/results`);
    assert.equal(resultsRes.status, 200);
    const resultsText = await resultsRes.text();
    assertNoSensitiveOrInternalLeak(resultsText, creds, jenkinsOrigin);
    assert.equal(resultsText.includes(backend.dataDir), false);

    const resultsJson = JSON.parse(resultsText) as {
      analysisId: string;
      status: string;
      metrics: { repository: { commitHistoryAvailable: boolean } };
      summaryMarkdown: string;
      charts: { commitsPerAuthor: string | null; dailyActivity: string | null };
    };
    assert.equal(resultsJson.analysisId, activeId);
    assert.equal(resultsJson.status, 'COMPLETED');
    assert.equal(resultsJson.metrics.repository.commitHistoryAvailable, true);
    assert.equal(resultsJson.charts.commitsPerAuthor, `/api/analyses/${activeId}/charts/commits_per_author.png`);
    assert.equal(resultsJson.charts.dailyActivity, `/api/analyses/${activeId}/charts/daily_commit_activity.png`);

    for (const chartName of ['commits_per_author.png', 'daily_commit_activity.png']) {
      const chartRes = await fetch(`${backend.baseUrl}/api/analyses/${activeId}/charts/${chartName}`);
      assert.equal(chartRes.status, 200);
      assert.equal(chartRes.headers.get('content-type'), 'image/png');
      assert.ok(Buffer.from(await chartRes.arrayBuffer()).equals(samplePng));
      const stat = await fsPromises.stat(path.join(backend.dataDir, 'artifacts', activeId, chartName));
      assert.equal(stat.mode & 0o111, 0, 'Cached chart files must never have execute bits');
    }

    // 2. Zero-commit repository (.git stripped before REPO_URL, HTTP 302 relative Location)
    const zeroSubmit = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Empty-Repo.git');
    assert.equal(zeroSubmit.status, 202);
    const zeroId = String(zeroSubmit.json['analysisId']);
    assert.deepEqual(dispatches[1]?.params, { REPO_URL: 'https://github.com/octocat/Empty-Repo' });

    const zeroDone = await waitForStatus(backend.baseUrl, zeroId, (b) => b['status'] === 'COMPLETED');
    assertNoSensitiveOrInternalLeak(JSON.stringify(zeroDone), creds, jenkinsOrigin);
    const zeroResultsRes = await fetch(`${backend.baseUrl}/api/analyses/${zeroId}/results`);
    assert.equal(zeroResultsRes.status, 200);
    const zeroResults = (await zeroResultsRes.json()) as {
      charts: { commitsPerAuthor: string | null; dailyActivity: string | null };
    };
    assert.deepEqual(zeroResults.charts, { commitsPerAuthor: null, dailyActivity: null });
    const zeroChartRes = await fetch(`${backend.baseUrl}/api/analyses/${zeroId}/charts/commits_per_author.png`);
    assert.equal(zeroChartRes.status, 404);
  } finally {
    await backend.close();
    await jenkinsServer.close();
  }
});

test('Phase 7.3 [Auth, CSRF & Restart Recovery]: Enforces dynamic CSRF headers, rejects bad/missing auth cleanly, and resumes live polling after restart without re-dispatching', async () => {
  const creds = generateEphemeralCreds('X-Jenkins-CSRF-Token');
  const samplePng = createSamplePngBuffer();
  let mode: 'ok' | 'bad_token_dispatch' | 'missing_crumb_dispatch' | 'bad_token_poll' = 'ok';
  let triggerPosts = 0;
  let crumbGets = 0;
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer(async (req, res) => {
    if (req.headers.authorization !== creds.expectedAuthHeader) {
      res.writeHead(401).end('Invalid API credentials');
      return;
    }

    const reqUrl = req.url ?? '/';

    if (reqUrl === '/crumbIssuer/api/json') {
      crumbGets += 1;
      if (mode === 'bad_token_dispatch') {
        res.writeHead(401).end('Expired token');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          _class: 'hudson.security.csrf.DefaultCrumbIssuer',
          crumbRequestField: creds.crumbField,
          crumb: creds.crumbValue,
        }),
      );
      return;
    }

    if (reqUrl === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      triggerPosts += 1;
      const incoming = req.headers[creds.crumbField.toLowerCase()];
      if (mode === 'missing_crumb_dispatch' || incoming !== creds.crumbValue) {
        res.writeHead(403).end('No valid crumb was included in the request');
        return;
      }
      res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/301/` }).end();
      return;
    }

    if (mode === 'bad_token_poll') {
      res.writeHead(403).end('Permission revoked mid-poll');
      return;
    }

    if (reqUrl === '/queue/item/301/api/json' || reqUrl === '/queue/item/501/api/json') {
      const bNum = reqUrl.includes('/301/') ? 61 : 62;
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          cancelled: false,
          executable: { number: bNum, url: `${jenkinsOrigin}/job/git-repo-analyzer/${bNum}/` },
        }),
      );
      return;
    }

    if (reqUrl === '/job/git-repo-analyzer/62/api/json' || reqUrl === '/job/git-repo-analyzer/63/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          building: false,
          result: 'SUCCESS',
          duration: 1200,
          url: `${jenkinsOrigin}/job/git-repo-analyzer/62/`,
          artifacts: [
            { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
            { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
            { fileName: 'commits_per_author.png', relativePath: 'target-repo/reports/charts/commits_per_author.png' },
            { fileName: 'daily_commit_activity.png', relativePath: 'target-repo/reports/charts/daily_commit_activity.png' },
          ],
        }),
      );
      return;
    }

    if (reqUrl.endsWith('/artifact/target-repo/reports/metrics.json')) {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify(buildSampleMetrics('https://github.com/octocat/Hello-World')),
      );
      return;
    }
    if (reqUrl.endsWith('/artifact/target-repo/reports/summary.md')) {
      res.writeHead(200, { 'Content-Type': 'text/markdown' }).end(
        buildSampleMarkdown('https://github.com/octocat/Hello-World'),
      );
      return;
    }
    if (reqUrl.endsWith('.png')) {
      res.writeHead(200, { 'Content-Type': 'image/png' }).end(samplePng);
      return;
    }

    res.writeHead(404).end();
  });
  jenkinsOrigin = jenkinsServer.origin;

  const backend = await startBackendHarness({ jenkinsOrigin, creds, pollIntervalMs: 15 });
  try {
    // 1. Wrong/expired credentials on crumb issuer during dispatch -> 503 + persisted FAILED
    mode = 'bad_token_dispatch';
    const badAuthRes = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(badAuthRes.status, 503);
    assertNoSensitiveOrInternalLeak(badAuthRes.bodyText, creds, jenkinsOrigin);
    const badAuthId = String((badAuthRes.json['error'] as { details: { analysisId: string } }).details.analysisId);
    const badAuthStatus = await fetch(`${backend.baseUrl}/api/analyses/${badAuthId}`);
    const badAuthStatusJson = (await badAuthStatus.json()) as { status: string; error: { code: string } };
    assert.equal(badAuthStatusJson.status, 'FAILED');
    assert.equal(badAuthStatusJson.error.code, 'DISPATCH_FAILED');

    // 2. Rejected crumb on POST buildWithParameters -> 503 + persisted FAILED
    mode = 'missing_crumb_dispatch';
    const badCrumbRes = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(badCrumbRes.status, 503);
    assertNoSensitiveOrInternalLeak(badCrumbRes.bodyText, creds, jenkinsOrigin);

    // 3. Auth failure mid-polling (after dispatch succeeds) -> FAILED PIPELINE_POLL_FAILED
    mode = 'ok';
    const okDispatch = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(okDispatch.status, 202);
    mode = 'bad_token_poll';
    const pollFailId = String(okDispatch.json['analysisId']);
    const pollFailState = await waitForStatus(backend.baseUrl, pollFailId, (b) => b['status'] === 'FAILED');
    assert.equal((pollFailState['error'] as { code: string }).code, 'PIPELINE_POLL_FAILED');
    assertNoSensitiveOrInternalLeak(JSON.stringify(pollFailState), creds, jenkinsOrigin);

    // 4. Restart recovery resumes QUEUED (queueId) and BUILDING (buildNumber) over live HTTP with zero re-triggers
    mode = 'ok';
    await backend.analysisManager.stop();
    const triggerSnapshot = triggerPosts;
    const crumbSnapshot = crumbGets;

    const queuedId = randomUUID();
    const buildingId = randomUUID();
    const nowIso = new Date().toISOString();

    await backend.store.save({
      analysisId: queuedId,
      repositoryUrl: 'https://github.com/octocat/Recovered-Queue',
      status: 'QUEUED',
      progress: 'Persisted queue state before restart',
      createdAt: nowIso,
      updatedAt: nowIso,
      error: null,
      queueId: 501,
      buildNumber: null,
      results: null,
    });
    await backend.store.save({
      analysisId: buildingId,
      repositoryUrl: 'https://github.com/octocat/Recovered-Build',
      status: 'BUILDING',
      progress: 'Persisted build state before restart',
      createdAt: nowIso,
      updatedAt: nowIso,
      error: null,
      queueId: 502,
      buildNumber: 63,
      results: null,
    });

    const restartedStore = new FileAnalysisStore(backend.dataDir);
    await restartedStore.initialize({ maxInFlightAgeMs: 60_000 });
    const restartedManager = new AnalysisManager({
      store: restartedStore,
      artifactIngestor: new ArtifactIngestor(backend.dataDir),
      jenkinsClient: new LiveJenkinsClient({
        baseUrl: jenkinsOrigin,
        username: creds.username,
        apiToken: creds.apiToken,
        jobName: 'git-repo-analyzer',
      }),
      ssrfCheckDns: true,
      analysisTimeoutMs: 60_000,
      pollIntervalMs: 15,
    });

    const resumedCount = restartedManager.resumePendingAnalyses();
    assert.equal(resumedCount, 2);

    for (let i = 0; i < 80; i += 1) {
      if (
        restartedManager.getPublicStatus(queuedId).status === 'COMPLETED' &&
        restartedManager.getPublicStatus(buildingId).status === 'COMPLETED'
      ) {
        break;
      }
      await new Promise((r) => setTimeout(r, 15));
    }

    assert.equal(restartedManager.getPublicStatus(queuedId).status, 'COMPLETED');
    assert.equal(restartedManager.getPublicStatus(buildingId).status, 'COMPLETED');
    assert.equal(triggerPosts, triggerSnapshot, 'Restart recovery must never re-trigger Jenkins POST');
    assert.equal(crumbGets, crumbSnapshot, 'Restart recovery must never request new trigger crumbs');
    await restartedManager.stop();
  } finally {
    await backend.close();
    await jenkinsServer.close();
  }
});

test('Phase 7.3 [Build Lifecycle]: Handles queue cancellation and build ABORTED/FAILURE/UNSTABLE terminals cleanly', async () => {
  const creds = generateEphemeralCreds();
  let seq = 0;
  const routeByQueue = new Map<number, 'queue_cancel' | 'aborted' | 'failure' | 'unstable'>();
  const routeByBuild = new Map<number, 'aborted' | 'failure' | 'unstable'>();
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer(async (req, res) => {
    if (req.headers.authorization !== creds.expectedAuthHeader) {
      res.writeHead(401).end();
      return;
    }
    const reqUrl = req.url ?? '/';
    if (reqUrl === '/crumbIssuer/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ crumbRequestField: creds.crumbField, crumb: creds.crumbValue }),
      );
      return;
    }
    if (reqUrl === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      const body = await readRequestBody(req);
      const repoUrl = new URLSearchParams(body).get('REPO_URL') ?? '';
      seq += 1;
      const scenario = repoUrl.endsWith('/QCancel')
        ? 'queue_cancel'
        : repoUrl.endsWith('/Aborted')
          ? 'aborted'
          : repoUrl.endsWith('/Unstable')
            ? 'unstable'
            : 'failure';
      routeByQueue.set(seq, scenario);
      routeByBuild.set(seq, scenario === 'queue_cancel' ? 'aborted' : scenario);
      res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/${seq}/` }).end();
      return;
    }
    const qMatch = reqUrl.match(/^\/queue\/item\/(\d+)\/api\/json$/);
    if (qMatch) {
      const id = Number(qMatch[1]);
      if (routeByQueue.get(id) === 'queue_cancel') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({ cancelled: true, executable: null }),
        );
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({
            cancelled: false,
            executable: { number: id, url: `${jenkinsOrigin}/job/git-repo-analyzer/${id}/` },
          }),
        );
      }
      return;
    }
    const bMatch = reqUrl.match(/^\/job\/git-repo-analyzer\/(\d+)\/api\/json$/);
    if (bMatch) {
      const id = Number(bMatch[1]);
      const kind = routeByBuild.get(id) ?? 'failure';
      const terminal = kind === 'aborted' ? 'ABORTED' : kind === 'unstable' ? 'UNSTABLE' : 'FAILURE';
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ building: false, result: terminal, duration: 500, artifacts: [] }),
      );
      return;
    }
    res.writeHead(404).end();
  });
  jenkinsOrigin = jenkinsServer.origin;

  const backend = await startBackendHarness({ jenkinsOrigin, creds, pollIntervalMs: 12 });
  try {
    const cases: Array<{ repo: string; expectedStatus: 'CANCELLED' | 'FAILED'; expectedErrCode: string | null }> = [
      { repo: 'https://github.com/octocat/QCancel', expectedStatus: 'CANCELLED', expectedErrCode: null },
      { repo: 'https://github.com/octocat/Aborted', expectedStatus: 'CANCELLED', expectedErrCode: null },
      { repo: 'https://github.com/octocat/Failure', expectedStatus: 'FAILED', expectedErrCode: 'ANALYSIS_FAILED' },
      { repo: 'https://github.com/octocat/Unstable', expectedStatus: 'FAILED', expectedErrCode: 'ANALYSIS_FAILED' },
    ];

    for (const c of cases) {
      const sub = await submitAnalysis(backend.baseUrl, c.repo);
      assert.equal(sub.status, 202);
      const analysisId = String(sub.json['analysisId']);
      const finalBody = await waitForStatus(
        backend.baseUrl,
        analysisId,
        (b) => b['status'] === 'COMPLETED' || b['status'] === 'FAILED' || b['status'] === 'CANCELLED',
      );
      assertNoSensitiveOrInternalLeak(JSON.stringify(finalBody), creds, jenkinsOrigin);
      assert.equal(finalBody['status'], c.expectedStatus);
      const errObj = finalBody['error'] as { code?: string } | null;
      assert.equal(errObj ? errObj.code : null, c.expectedErrCode);

      const resCheck = await fetch(`${backend.baseUrl}/api/analyses/${analysisId}/results`);
      assert.equal(resCheck.status, 409);
      const chartCheck = await fetch(`${backend.baseUrl}/api/analyses/${analysisId}/charts/commits_per_author.png`);
      assert.equal(chartCheck.status, 409);
    }
  } finally {
    await backend.close();
    await jenkinsServer.close();
  }
});

test('Phase 7.3 [Artifact Protocol]: Rejects missing, incomplete, malformed, spoofed, oversized, and traversal artifacts over HTTP', async () => {
  const creds = generateEphemeralCreds();
  const samplePng = createSamplePngBuffer();
  const validMetrics = JSON.stringify(buildSampleMetrics('https://github.com/octocat/Hello-World'));
  const validSummary = buildSampleMarkdown('https://github.com/octocat/Hello-World');
  let traversalDownloadHit = false;
  let buildSeq = 0;
  const scenarioByBuild = new Map<number, string>();
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer(async (req, res) => {
    if (req.headers.authorization !== creds.expectedAuthHeader) {
      res.writeHead(401).end();
      return;
    }
    const reqUrl = req.url ?? '/';
    if (reqUrl === '/crumbIssuer/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ crumbRequestField: creds.crumbField, crumb: creds.crumbValue }),
      );
      return;
    }
    if (reqUrl === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      const body = await readRequestBody(req);
      const repoUrl = new URLSearchParams(body).get('REPO_URL') ?? '';
      const scenarioName = repoUrl.split('/').pop() ?? '';
      buildSeq += 1;
      scenarioByBuild.set(buildSeq, scenarioName);
      res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/${buildSeq}/` }).end();
      return;
    }
    const qMatch = reqUrl.match(/^\/queue\/item\/(\d+)\/api\/json$/);
    if (qMatch) {
      const id = Number(qMatch[1]);
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          cancelled: false,
          executable: { number: id, url: `${jenkinsOrigin}/job/git-repo-analyzer/${id}/` },
        }),
      );
      return;
    }
    const bMatch = reqUrl.match(/^\/job\/git-repo-analyzer\/(\d+)\/api\/json$/);
    if (bMatch) {
      const id = Number(bMatch[1]);
      const sc = scenarioByBuild.get(id) ?? 'unknown';
      const defaultArtifacts = [
        { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
        { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
        { fileName: 'commits_per_author.png', relativePath: 'target-repo/reports/charts/commits_per_author.png' },
        { fileName: 'daily_commit_activity.png', relativePath: 'target-repo/reports/charts/daily_commit_activity.png' },
      ];

      let artifacts = defaultArtifacts;
      if (sc === 'missing-metrics') {
        artifacts = defaultArtifacts.filter((a) => a.fileName !== 'metrics.json');
      } else if (sc === 'missing-summary') {
        artifacts = defaultArtifacts.filter((a) => a.fileName !== 'summary.md');
      } else if (sc === 'missing-daily-png') {
        artifacts = defaultArtifacts.filter((a) => a.fileName !== 'daily_commit_activity.png');
      } else if (sc === 'traversal-artifact') {
        artifacts = [{ fileName: 'passwd', relativePath: '../../etc/passwd' }];
      }

      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ building: false, result: 'SUCCESS', duration: 800, artifacts }),
      );
      return;
    }

    const aMatch = reqUrl.match(/^\/job\/git-repo-analyzer\/(\d+)\/artifact\/(.+)$/);
    if (aMatch) {
      const id = Number(aMatch[1]);
      const sc = scenarioByBuild.get(id) ?? '';
      const rel = decodeURIComponent(aMatch[2] ?? '');

      if (rel.includes('etc/passwd')) {
        traversalDownloadHit = true;
      }

      if (rel.endsWith('metrics.json')) {
        if (sc === 'malformed-json') {
          res.writeHead(200, { 'Content-Type': 'application/json' }).end('{bad json');
          return;
        }
        if (sc === 'invalid-schema') {
          res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ wrong: true }));
          return;
        }
        if (sc === 'artifact-http-500') {
          res.writeHead(500).end('Disk read error');
          return;
        }
        if (sc === 'oversized-metrics') {
          res.writeHead(200, { 'Content-Type': 'application/json' }).end(' '.repeat(4096));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(validMetrics);
        return;
      }

      if (rel.endsWith('summary.md')) {
        if (sc === 'empty-summary') {
          res.writeHead(200, { 'Content-Type': 'text/markdown' }).end('   \n  ');
          return;
        }
        if (sc === 'nul-summary') {
          res.writeHead(200, { 'Content-Type': 'text/markdown' }).end(Buffer.from('Hello\x00World'));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'text/markdown' }).end(validSummary);
        return;
      }

      if (rel.endsWith('.png')) {
        if (sc === 'spoofed-png' && rel.endsWith('commits_per_author.png')) {
          res.writeHead(200, { 'Content-Type': 'image/png' }).end('<html><script>alert(1)</script></html>');
          return;
        }
        res.writeHead(200, { 'Content-Type': 'image/png' }).end(samplePng);
        return;
      }
    }

    res.writeHead(404).end();
  });
  jenkinsOrigin = jenkinsServer.origin;

  const backend = await startBackendHarness({
    jenkinsOrigin,
    creds,
    pollIntervalMs: 12,
    maxArtifactBytes: 2048,
  });

  try {
    const scenarios: Array<{ slug: string; expectedErrCode: string }> = [
      { slug: 'missing-metrics', expectedErrCode: 'PIPELINE_POLL_FAILED' },
      { slug: 'missing-summary', expectedErrCode: 'PIPELINE_POLL_FAILED' },
      { slug: 'missing-daily-png', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'malformed-json', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'invalid-schema', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'empty-summary', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'nul-summary', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'spoofed-png', expectedErrCode: 'ARTIFACT_INGESTION_FAILED' },
      { slug: 'traversal-artifact', expectedErrCode: 'PIPELINE_POLL_FAILED' },
      { slug: 'artifact-http-500', expectedErrCode: 'PIPELINE_POLL_FAILED' },
      { slug: 'oversized-metrics', expectedErrCode: 'PIPELINE_POLL_FAILED' },
    ];

    for (const s of scenarios) {
      const sub = await submitAnalysis(backend.baseUrl, `https://github.com/octocat/${s.slug}`);
      assert.equal(sub.status, 202);
      const id = String(sub.json['analysisId']);
      const finalBody = await waitForStatus(
        backend.baseUrl,
        id,
        (b) => b['status'] === 'COMPLETED' || b['status'] === 'FAILED' || b['status'] === 'CANCELLED',
      );
      assert.equal(finalBody['status'], 'FAILED', `Expected FAILED for ${s.slug}`);
      assert.equal((finalBody['error'] as { code: string }).code, s.expectedErrCode, `Error code mismatch for ${s.slug}`);

      const resGate = await fetch(`${backend.baseUrl}/api/analyses/${id}/results`);
      assert.equal(resGate.status, 409);

      if (s.slug === 'spoofed-png') {
        await assert.rejects(
          () => fsPromises.stat(path.join(backend.dataDir, 'artifacts', id, 'commits_per_author.png')),
          { code: 'ENOENT' },
        );
      }
    }

    assert.equal(traversalDownloadHit, false, 'Backend must reject traversal relativePath before downloading artifact');
  } finally {
    await backend.close();
    await jenkinsServer.close();
  }
});

test('Phase 7.3 [Failure Modes]: Handles Jenkins unavailability, HTTP 500/404 dispatches, missing/invalid Location, cross-origin redirects, timeouts, and malformed JSON cleanly', async () => {
  const creds = generateEphemeralCreds();
  let evilHits = 0;
  const evilServer = await startHttpServer((_req, res) => {
    evilHits += 1;
    res.writeHead(200).end('stolen');
  });

  type ControllerMode =
    | 'dispatch_500'
    | 'dispatch_404'
    | 'dispatch_no_location'
    | 'dispatch_bad_location'
    | 'dispatch_cross_origin_redirect'
    | 'dispatch_timeout'
    | 'dispatch_bad_crumb_json'
    | 'poll_timeout'
    | 'poll_bad_queue_json'
    | 'poll_bad_build_schema'
    | 'poll_cross_origin_build_url';

  let activeMode: ControllerMode = 'dispatch_500';
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer((req, res) => {
    if (req.headers.authorization !== creds.expectedAuthHeader) {
      res.writeHead(401).end();
      return;
    }
    const reqUrl = req.url ?? '/';

    if (reqUrl === '/crumbIssuer/api/json') {
      if (activeMode === 'dispatch_bad_crumb_json') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end('{corrupt-crumb');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ crumbRequestField: creds.crumbField, crumb: creds.crumbValue }),
      );
      return;
    }

    if (reqUrl === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      if (activeMode === 'dispatch_500') {
        res.writeHead(500).end('Jenkins Internal Server Error');
        return;
      }
      if (activeMode === 'dispatch_404') {
        res.writeHead(404).end('Job not found');
        return;
      }
      if (activeMode === 'dispatch_no_location') {
        res.writeHead(201).end();
        return;
      }
      if (activeMode === 'dispatch_bad_location') {
        res.writeHead(201, { Location: `${jenkinsOrigin}/unexpected/path` }).end();
        return;
      }
      if (activeMode === 'dispatch_cross_origin_redirect') {
        res.writeHead(302, { Location: `${evilServer.origin}/queue/item/999/` }).end();
        return;
      }
      if (activeMode === 'dispatch_timeout') {
        // Hold open until LiveJenkinsClient requestTimeoutMs aborts
        return;
      }
      res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/801/` }).end();
      return;
    }

    if (reqUrl === '/queue/item/801/api/json') {
      if (activeMode === 'poll_bad_queue_json') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end('not-json');
        return;
      }
      if (activeMode === 'poll_timeout') {
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          cancelled: false,
          executable: { number: 88, url: `${jenkinsOrigin}/job/git-repo-analyzer/88/` },
        }),
      );
      return;
    }

    if (reqUrl === '/job/git-repo-analyzer/88/api/json') {
      if (activeMode === 'poll_bad_build_schema') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ unexpected: 123 }));
        return;
      }
      if (activeMode === 'poll_cross_origin_build_url') {
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(
          JSON.stringify({
            building: false,
            result: 'SUCCESS',
            url: `${evilServer.origin}/job/evil/88/`,
            artifacts: [],
          }),
        );
        return;
      }
    }

    res.writeHead(404).end();
  });
  jenkinsOrigin = jenkinsServer.origin;

  let backend: BackendHarness | null = null;
  try {
    backend = await startBackendHarness({
      jenkinsOrigin,
      creds,
      requestTimeoutMs: 550,
      pollIntervalMs: 12,
    });
    const dispatchModes: ControllerMode[] = [
      'dispatch_500',
      'dispatch_404',
      'dispatch_no_location',
      'dispatch_bad_location',
      'dispatch_cross_origin_redirect',
      'dispatch_timeout',
      'dispatch_bad_crumb_json',
    ];

    for (const m of dispatchModes) {
      activeMode = m;
      const sub = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
      assert.equal(sub.status, 503, `Expected 503 for ${m}`);
      assertNoSensitiveOrInternalLeak(sub.bodyText, creds, jenkinsOrigin);
      const id = String((sub.json['error'] as { details: { analysisId: string } }).details.analysisId);
      const stored = backend.store.getById(id);
      assert.equal(stored?.status, 'FAILED');
      assert.equal(stored?.error?.code, 'DISPATCH_FAILED');
    }
    assert.equal(evilHits, 0, 'Cross-origin redirect must receive zero requests');

    const pollModes: ControllerMode[] = [
      'poll_timeout',
      'poll_bad_queue_json',
      'poll_bad_build_schema',
      'poll_cross_origin_build_url',
    ];
    for (const m of pollModes) {
      activeMode = m;
      const sub = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
      assert.equal(sub.status, 202, `Initial dispatch should succeed for ${m}`);
      const id = String(sub.json['analysisId']);
      const finalBody = await waitForStatus(backend.baseUrl, id, (b) => b['status'] === 'FAILED');
      assert.equal((finalBody['error'] as { code: string }).code, 'PIPELINE_POLL_FAILED');
      assertNoSensitiveOrInternalLeak(JSON.stringify(finalBody), creds, jenkinsOrigin);
    }

    // Closed controller port (Jenkins completely offline)
    await jenkinsServer.close();
    const offlineRes = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(offlineRes.status, 503);
    assertNoSensitiveOrInternalLeak(offlineRes.bodyText, creds, jenkinsOrigin);
  } finally {
    if (backend) {
      await backend.close();
    }
    await jenkinsServer.close().catch(() => undefined);
    await evilServer.close();
  }
});

test('Phase 7.3 [Security & Contract Parity]: Enforces no shell interpolation, zero credential log/disk leaks, zero GROQ_API_KEY/Docker socket in Jenkinsfile, and static report fallback compatibility', async () => {
  const creds = generateEphemeralCreds();
  let jenkinsHits = 0;
  const jenkinsServer = await startHttpServer((_req, res) => {
    jenkinsHits += 1;
    res.writeHead(500).end();
  });

  const capturedLogs: string[] = [];
  const origLog = console.log;
  const origError = console.error;
  console.log = (...args: unknown[]) => {
    capturedLogs.push(args.map(String).join(' '));
  };
  console.error = (...args: unknown[]) => {
    capturedLogs.push(args.map(String).join(' '));
  };

  let backend: BackendHarness | null = null;
  try {
    backend = await startBackendHarness({ jenkinsOrigin: jenkinsServer.origin, creds, requestTimeoutMs: 550 });

    // 1. Unsafe inputs rejected before touching Jenkins
    const dangerousInputs = [
      'https://github.com/octocat/repo;id',
      'https://github.com/octocat/repo;rm -rf /',
      'https://github.com/octocat/repo$(id)',
      'https://github.com/octocat/repo`whoami`',
      'https://github.com/octocat/repo\nREPO_URL=evil',
      'https://user:pass@github.com/octocat/Hello-World',
      'http://github.com/octocat/Hello-World',
      'https://169.254.169.254/latest/meta-data/',
    ];

    for (const badInput of dangerousInputs) {
      const res = await submitAnalysis(backend.baseUrl, badInput);
      assert.equal(res.status, 400, `Expected 400 rejection for ${badInput}`);
      assertNoSensitiveOrInternalLeak(res.bodyText, creds, jenkinsServer.origin);
    }
    assert.equal(jenkinsHits, 0, 'Validation/SSRF rejections must never invoke Jenkins HTTP requests');

    // 2. Trigger failure with offline Jenkins and verify logs + persisted store leak zero secrets
    await jenkinsServer.close();
    const failRes = await submitAnalysis(backend.baseUrl, 'https://github.com/octocat/Hello-World');
    assert.equal(failRes.status, 503);
    assertNoSensitiveOrInternalLeak(failRes.bodyText, creds, jenkinsServer.origin);

    const diskStoreRaw = await fsPromises.readFile(backend.store.stateFilePath, 'utf8');
    assert.equal(diskStoreRaw.includes(creds.apiToken), false);
    assert.equal(diskStoreRaw.includes(creds.expectedAuthHeader), false);
    assert.equal(diskStoreRaw.includes(creds.crumbValue), false);
    assert.equal(diskStoreRaw.includes(creds.username), false);

    const joinedLogs = capturedLogs.join('\n');
    assert.equal(joinedLogs.includes(creds.apiToken), false);
    assert.equal(joinedLogs.includes(creds.expectedAuthHeader), false);

    // 3. Cross-check Jenkinsfile & static-report fallback parity against backend protocol expectations
    const repoRoot = path.resolve(
      __dirname,
      __dirname.split(path.sep).includes('dist-test') ? '../../..' : '../..',
    );
    const jenkinsfile = await fsPromises.readFile(path.join(repoRoot, 'Jenkinsfile'), 'utf8');
    assert.ok(jenkinsfile.includes("name: 'REPO_URL'"));
    assert.ok(jenkinsfile.includes('github.com'));
    assert.ok(jenkinsfile.includes('"$REPO_URL"'));
    assert.ok(jenkinsfile.includes('--user "$(id -u):$(id -g)"'));
    assert.ok(jenkinsfile.includes('--memory=768m'));
    assert.ok(jenkinsfile.includes("archiveArtifacts artifacts: 'target-repo/reports/**/*'"));
    assert.equal(jenkinsfile.includes('/var/run/docker.sock'), false);
    assert.equal(jenkinsfile.includes('GROQ_API_KEY'), false);

    const reportGen = await fsPromises.readFile(path.join(repoRoot, 'ai/reportGenerator.js'), 'utf8');
    assert.ok(reportGen.includes('if (!process.env.GROQ_API_KEY)'));
    assert.ok(reportGen.includes('writeStaticReport();'));
  } finally {
    console.log = origLog;
    console.error = origError;
    if (backend) {
      await backend.close();
    }
    await jenkinsServer.close().catch(() => undefined);
  }
});
