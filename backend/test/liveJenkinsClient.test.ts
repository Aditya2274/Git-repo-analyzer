import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';
import { JenkinsClientError, LiveJenkinsClient } from '../src/services/liveJenkinsClient';
import { buildSampleMarkdown, buildSampleMetrics, createSamplePngBuffer } from '../src/services/mockJenkinsClient';

const SECRET_TOKEN = 'super-secret-jenkins-token-12345';
const TEST_USER = 'backend-service';

async function startHttpServer(
  handler: http.RequestListener,
): Promise<{ origin: string; close: () => Promise<void> }> {
  const server = http.createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  if (!addr || typeof addr === 'string') {
    throw new Error('Expected ephemeral TCP port');
  }
  return {
    origin: `http://127.0.0.1:${addr.port}`,
    close: () => new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve()))),
  };
}

test('LiveJenkinsClient handles Basic Auth, CSRF crumb, trigger, queue resolution, build metadata, and artifact download cleanly', async () => {
  const seenRequests: Array<{ method: string; url: string; auth: string | undefined; crumb: string | undefined; body: string }> = [];
  const samplePng = createSamplePngBuffer();
  const sampleMetrics = JSON.stringify(buildSampleMetrics('https://github.com/octocat/Hello-World'));
  const sampleSummary = buildSampleMarkdown('https://github.com/octocat/Hello-World');
  let jenkinsOrigin = '';

  const jenkinsServer = await startHttpServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      chunks.push(Buffer.from(chunk));
    }
    const body = Buffer.concat(chunks).toString('utf8');
    seenRequests.push({
      method: req.method ?? '',
      url: req.url ?? '',
      auth: req.headers.authorization,
      crumb: req.headers['jenkins-crumb'] as string | undefined,
      body,
    });

    const expectedAuth = `Basic ${Buffer.from(`${TEST_USER}:${SECRET_TOKEN}`).toString('base64')}`;
    if (req.headers.authorization !== expectedAuth) {
      res.writeHead(401).end('Unauthorized');
      return;
    }

    if (req.url === '/crumbIssuer/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ crumbRequestField: 'Jenkins-Crumb', crumb: 'csrf-crumb-99' }));
      return;
    }

    if (req.url === '/job/git-repo-analyzer/buildWithParameters' && req.method === 'POST') {
      res.writeHead(201, { Location: `${jenkinsOrigin}/queue/item/77/` });
      res.end();
      return;
    }

    if (req.url === '/queue/item/77/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          cancelled: false,
          executable: { number: 15, url: `${jenkinsOrigin}/job/git-repo-analyzer/15/` },
        }),
      );
      return;
    }

    if (req.url === '/job/git-repo-analyzer/15/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          building: false,
          result: 'SUCCESS',
          duration: 4200,
          url: `${jenkinsOrigin}/job/git-repo-analyzer/15/`,
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

    if (req.url === '/job/git-repo-analyzer/15/artifact/target-repo/reports/metrics.json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(sampleMetrics);
      return;
    }
    if (req.url === '/job/git-repo-analyzer/15/artifact/target-repo/reports/summary.md') {
      res.writeHead(200, { 'Content-Type': 'text/markdown' }).end(sampleSummary);
      return;
    }
    if (
      req.url === '/job/git-repo-analyzer/15/artifact/target-repo/reports/charts/commits_per_author.png' ||
      req.url === '/job/git-repo-analyzer/15/artifact/target-repo/reports/charts/daily_commit_activity.png'
    ) {
      res.writeHead(200, { 'Content-Type': 'image/png' }).end(samplePng);
      return;
    }

    res.writeHead(404).end('Not found');
  });
  jenkinsOrigin = jenkinsServer.origin;

  try {
    const client = new LiveJenkinsClient({
      baseUrl: jenkinsOrigin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'git-repo-analyzer',
      requestTimeoutMs: 2000,
    });

    const triggered = await client.triggerJob('https://github.com/octocat/Hello-World');
    assert.equal(triggered.queueId, 77);

    const postReq = seenRequests.find((r) => r.method === 'POST');
    assert.ok(postReq);
    assert.equal(postReq.crumb, 'csrf-crumb-99');
    assert.equal(postReq.body, 'REPO_URL=https%3A%2F%2Fgithub.com%2Foctocat%2FHello-World');

    const queued = await client.getBuildFromQueue(77);
    assert.deepEqual(queued, { resolved: true, cancelled: false, buildNumber: 15 });

    const status = await client.getBuildStatus(15);
    assert.equal(status.building, false);
    assert.equal(status.result, 'SUCCESS');

    const bundle = await client.fetchArtifact(15);
    assert.equal(bundle.metricsJson.toString('utf8'), sampleMetrics);
    assert.equal(bundle.summaryMarkdown.toString('utf8'), sampleSummary);
    assert.ok(bundle.commitsPerAuthorPng?.equals(samplePng));
    assert.ok(bundle.dailyActivityPng?.equals(samplePng));
  } finally {
    await jenkinsServer.close();
  }
});

test('LiveJenkinsClient blocks cross-origin redirects without leaking credentials, enforces size/schema/auth/timeout checks', async () => {
  let evilHits = 0;
  const evilServer = await startHttpServer((_req, res) => {
    evilHits += 1;
    res.writeHead(200).end('stolen');
  });

  const controller = await startHttpServer((req, res) => {
    if (req.url === '/crumbIssuer/api/json') {
      res.writeHead(404).end(); // Crumb issuer disabled
      return;
    }
    if (req.url === '/job/evil-redirect/buildWithParameters') {
      res.writeHead(302, { Location: `${evilServer.origin}/queue/item/99/` }).end();
      return;
    }
    if (req.url === '/job/auth-fail/buildWithParameters') {
      res.writeHead(401).end('Bad credentials');
      return;
    }
    if (req.url === '/queue/item/20/api/json') {
      // Untrusted external executable URL returned by compromised Jenkins payload
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ executable: { number: 5, url: `${evilServer.origin}/job/evil/5/` } }));
      return;
    }
    if (req.url === '/job/bad-schema/5/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ unexpected: true }));
      return;
    }
    if (req.url === '/job/traversal/5/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          building: false,
          result: 'SUCCESS',
          artifacts: [{ fileName: 'passwd', relativePath: '../../etc/passwd' }],
        }),
      );
      return;
    }
    if (req.url === '/job/slow/buildWithParameters') {
      // Never respond until client timeout aborts
      return;
    }
    res.writeHead(404).end();
  });

  try {
    // 1. Cross-origin redirect blocked without sending Basic Auth to evilServer
    const redirectClient = new LiveJenkinsClient({
      baseUrl: controller.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'evil-redirect',
      requestTimeoutMs: 1000,
    });
    await assert.rejects(
      () => redirectClient.triggerJob('https://github.com/octocat/Hello-World'),
      (err: unknown) =>
        err instanceof JenkinsClientError && err.code === 'JENKINS_UNTRUSTED_REDIRECT',
    );
    assert.equal(evilHits, 0, 'Cross-origin redirect must NOT send HTTP request or credentials');

    // 2. Authentication error does not leak token or Basic header
    const authClient = new LiveJenkinsClient({
      baseUrl: controller.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'auth-fail',
    });
    await assert.rejects(
      () => authClient.triggerJob('https://github.com/octocat/Hello-World'),
      (err: unknown) => {
        assert.ok(err instanceof JenkinsClientError && err.code === 'JENKINS_AUTH_FAILED');
        assert.ok(!err.message.includes(SECRET_TOKEN));
        assert.ok(!err.message.includes('Basic '));
        return true;
      },
    );

    // 3. Untrusted queue executable URL blocked
    await assert.rejects(
      () => authClient.getBuildFromQueue(20),
      (err: unknown) => err instanceof JenkinsClientError && err.code === 'JENKINS_UNTRUSTED_REDIRECT',
    );

    // 4. Malformed build schema rejected
    const schemaClient = new LiveJenkinsClient({
      baseUrl: controller.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'bad-schema',
    });
    await assert.rejects(
      () => schemaClient.getBuildStatus(5),
      (err: unknown) => err instanceof JenkinsClientError && err.code === 'JENKINS_INVALID_RESPONSE',
    );

    // 5. Path traversal artifact relativePath rejected
    const traversalClient = new LiveJenkinsClient({
      baseUrl: controller.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'traversal',
    });
    await assert.rejects(
      () => traversalClient.getBuildResult(5),
      (err: unknown) => err instanceof JenkinsClientError && err.code === 'JENKINS_INVALID_RESPONSE',
    );

    // 6. Timeout handled explicitly
    const slowClient = new LiveJenkinsClient({
      baseUrl: controller.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'slow',
      requestTimeoutMs: 120,
    });
    await assert.rejects(
      () => slowClient.triggerJob('https://github.com/octocat/Hello-World'),
      (err: unknown) =>
        err instanceof JenkinsClientError &&
        (err.code === 'JENKINS_TIMEOUT' || err.code === 'JENKINS_NETWORK_ERROR') &&
        !err.message.includes(SECRET_TOKEN),
    );
  } finally {
    await controller.close();
    await evilServer.close();
  }
});

test('LiveJenkinsClient handles crumb-disabled triggers, FAILURE builds, 404 builds, size caps, and network failures', async () => {
  const srv = await startHttpServer((req, res) => {
    if (req.url === '/crumbIssuer/api/json') {
      res.writeHead(404).end(); // Crumb disabled
      return;
    }
    if (req.url === '/job/no-crumb/buildWithParameters' && req.method === 'POST') {
      res.writeHead(302, { Location: `${srv.origin}/queue/item/55/` }).end();
      return;
    }
    if (req.url === '/job/no-crumb/9/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({ building: false, result: 'FAILURE', duration: 900, artifacts: [] }),
      );
      return;
    }
    if (req.url === '/job/oversized/1/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(
        JSON.stringify({
          building: false,
          result: 'SUCCESS',
          artifacts: [
            { fileName: 'metrics.json', relativePath: 'reports/metrics.json' },
            { fileName: 'summary.md', relativePath: 'reports/summary.md' },
          ],
        }),
      );
      return;
    }
    if (req.url === '/job/oversized/1/artifact/reports/metrics.json') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end('x'.repeat(2048));
      return;
    }
    res.writeHead(404).end();
  });

  try {
    const noCrumbClient = new LiveJenkinsClient({
      baseUrl: srv.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'no-crumb',
    });

    const trig = await noCrumbClient.triggerJob('https://github.com/octocat/Hello-World');
    assert.equal(trig.queueId, 55);

    const failBuild = await noCrumbClient.getBuildStatus(9);
    assert.equal(failBuild.building, false);
    assert.equal(failBuild.result, 'FAILURE');

    await assert.rejects(
      () => noCrumbClient.getBuildStatus(404),
      (err: unknown) => err instanceof JenkinsClientError && err.code === 'JENKINS_NOT_FOUND',
    );

    const cappedClient = new LiveJenkinsClient({
      baseUrl: srv.origin,
      username: TEST_USER,
      apiToken: SECRET_TOKEN,
      jobName: 'oversized',
      maxArtifactBytes: 512,
    });
    await assert.rejects(
      () => cappedClient.fetchArtifact(1),
      (err: unknown) => err instanceof JenkinsClientError && err.code === 'JENKINS_INVALID_RESPONSE',
    );
  } finally {
    await srv.close();
  }

  // Closed port network failure does not leak credentials
  const closedPortOrigin = srv.origin;
  const offlineClient = new LiveJenkinsClient({
    baseUrl: closedPortOrigin,
    username: TEST_USER,
    apiToken: SECRET_TOKEN,
    jobName: 'no-crumb',
  });
  await assert.rejects(
    () => offlineClient.getBuildStatus(1),
    (err: unknown) => {
      assert.ok(err instanceof JenkinsClientError && err.code === 'JENKINS_NETWORK_ERROR');
      assert.ok(!err.message.includes(SECRET_TOKEN));
      assert.ok(!err.message.includes('Basic '));
      return true;
    },
  );
});
