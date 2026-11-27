import assert from 'node:assert/strict';
import fsPromises from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import express from 'express';
import { createApp } from '../src/app';
import { loadConfig } from '../src/config/env';
import { createHealthRouter, resolveRuntimeReleaseId } from '../src/routes/health';
import { FileAnalysisStore } from '../src/services/analysisStore';

test('loadConfig validates defaults, boolean flags, production SSRF guard, and Jenkins conditional requirements', () => {
  const devCfg = loadConfig({ NODE_ENV: 'development' });
  assert.equal(devCfg.port, 3000);
  assert.equal(devCfg.host, '127.0.0.1');
  assert.equal(devCfg.ssrfCheckDns, true);
  assert.equal(devCfg.jenkins.mockMode, true);
  assert.deepEqual(devCfg.corsOrigins, ['http://localhost:5173']);

  const prodCfg = loadConfig({
    NODE_ENV: 'production',
    PORT: '3000',
    DATA_DIR: '/var/lib/git-repo-analyzer',
    JENKINS_MOCK_MODE: 'true',
  });
  assert.equal(prodCfg.nodeEnv, 'production');
  assert.deepEqual(prodCfg.corsOrigins, []);

  assert.throws(
    () => loadConfig({ NODE_ENV: 'production', SSRF_CHECK_DNS: 'false' }),
    /SSRF_CHECK_DNS cannot be disabled/,
  );

  assert.throws(
    () => loadConfig({ PORT: '99999' }),
    /Invalid backend environment configuration/,
  );

  assert.throws(
    () => loadConfig({ JENKINS_MOCK_MODE: 'not-a-bool' }),
    /Invalid boolean value/,
  );

  assert.throws(
    () => loadConfig({ JENKINS_MOCK_MODE: 'false', JENKINS_URL: 'http://cicd-server:8080' }),
    /JENKINS_URL, JENKINS_USER, and JENKINS_API_TOKEN are required/,
  );

  assert.throws(
    () => loadConfig({ NODE_ENV: 'production', CORS_ORIGIN: 'http://user:pass@127.0.0.1' }),
    /must not contain credentials/,
  );

  const multiCorsCfg = loadConfig({
    NODE_ENV: 'production',
    CORS_ORIGIN: 'https://app.example.com:8443, http://127.0.0.1:80',
  });
  assert.deepEqual(multiCorsCfg.corsOrigins, ['https://app.example.com:8443', 'http://127.0.0.1']);
});

async function startTestServer(store: FileAnalysisStore, corsOrigin = 'http://localhost:5173') {
  const config = loadConfig({
    NODE_ENV: 'test',
    DATA_DIR: store.dataDir,
    CORS_ORIGIN: corsOrigin,
  });
  const app = createApp({ config, store });
  const server = http.createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Unexpected server address');
  }
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve()))),
  };
}

test('GET /api/health returns 200 UP when store ready, 503 DOWN if uninitialized, and enforces CORS and JSON error format', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'git-repo-http-'));
  try {
    const uninitializedStore = new FileAnalysisStore(dataDir);
    const uninitServer = await startTestServer(uninitializedStore);
    try {
      const res503 = await fetch(`${uninitServer.baseUrl}/api/health`);
      assert.equal(res503.status, 503);
      const body503 = (await res503.json()) as { error: { code: string } };
      assert.equal(body503.error.code, 'SERVICE_UNAVAILABLE');
    } finally {
      await uninitServer.close();
    }

    const readyStore = new FileAnalysisStore(dataDir);
    await readyStore.initialize();
    const server = await startTestServer(readyStore);
    try {
      const healthRes = await fetch(`${server.baseUrl}/api/health`);
      assert.equal(healthRes.status, 200);
      assert.equal(healthRes.headers.get('x-content-type-options'), 'nosniff');
      assert.equal(healthRes.headers.get('x-frame-options'), 'DENY');
      assert.equal(healthRes.headers.get('x-powered-by'), null);

      const healthJson = (await healthRes.json()) as { status: string; timestamp: string };
      assert.equal(healthJson.status, 'UP');
      assert.ok(!Number.isNaN(Date.parse(healthJson.timestamp)));

      const allowedCors = await fetch(`${server.baseUrl}/api/health`, {
        headers: { Origin: 'http://localhost:5173' },
      });
      assert.equal(allowedCors.status, 200);
      assert.equal(allowedCors.headers.get('access-control-allow-origin'), 'http://localhost:5173');

      const blockedCors = await fetch(`${server.baseUrl}/api/health`, {
        headers: { Origin: 'https://evil.example.com' },
      });
      assert.equal(blockedCors.status, 403);
      assert.equal(blockedCors.headers.get('access-control-allow-origin'), null);
      const blockedJson = (await blockedCors.json()) as { error: { code: string } };
      assert.equal(blockedJson.error.code, 'CORS_FORBIDDEN');

      const emptyOriginCors = await fetch(`${server.baseUrl}/api/health`, {
        headers: { Origin: '' },
      });
      assert.equal(emptyOriginCors.status, 403);
      const emptyOriginJson = (await emptyOriginCors.json()) as { error: { code: string } };
      assert.equal(emptyOriginJson.error.code, 'CORS_FORBIDDEN');

      const nullOriginCors = await fetch(`${server.baseUrl}/api/health`, {
        headers: { Origin: 'null' },
      });
      assert.equal(nullOriginCors.status, 403);

      const malformedOriginCors = await fetch(`${server.baseUrl}/api/health`, {
        headers: { Origin: 'not-a-valid-origin' },
      });
      assert.equal(malformedOriginCors.status, 403);

      const allowedPreflight = await fetch(`${server.baseUrl}/api/analyses`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'http://localhost:5173',
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'Content-Type',
        },
      });
      assert.equal(allowedPreflight.status, 204);
      assert.equal(allowedPreflight.headers.get('access-control-allow-origin'), 'http://localhost:5173');
      assert.equal(allowedPreflight.headers.get('access-control-allow-credentials'), null);

      const blockedPreflight = await fetch(`${server.baseUrl}/api/analyses`, {
        method: 'OPTIONS',
        headers: {
          Origin: 'https://evil.example.com',
          'Access-Control-Request-Method': 'POST',
        },
      });
      assert.equal(blockedPreflight.status, 403);
      assert.equal(blockedPreflight.headers.get('access-control-allow-origin'), null);

      const notFoundRes = await fetch(`${server.baseUrl}/api/nonexistent`);
      assert.equal(notFoundRes.status, 404);
      const notFoundJson = (await notFoundRes.json()) as { error: { code: string; message: string; details: unknown } };
      assert.equal(notFoundJson.error.code, 'NOT_FOUND');
      assert.equal(notFoundJson.error.details, null);

      const badJsonRes = await fetch(`${server.baseUrl}/api/health`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{invalid-json',
      });
      assert.equal(badJsonRes.status, 400);
      const badJsonBody = (await badJsonRes.json()) as { error: { code: string } };
      assert.equal(badJsonBody.error.code, 'INVALID_JSON');
    } finally {
      await server.close();
    }

    // Release metadata identity: frozen from manifest without leaking filesystem paths or secrets
    const manifestPath = path.join(dataDir, 'release-manifest.json');
    await fsPromises.writeFile(
      manifestPath,
      JSON.stringify({ releaseId: '2.4.1', gitCommit: 'abc123', builtAt: '2026-11-26T00:00:00Z' }),
      'utf8',
    );
    assert.equal(resolveRuntimeReleaseId(manifestPath), '2.4.1');
    const badManifestPath = path.join(dataDir, 'bad-release-manifest.json');
    await fsPromises.writeFile(badManifestPath, JSON.stringify({ releaseId: '../evil' }), 'utf8');
    assert.equal(resolveRuntimeReleaseId(badManifestPath), null);

    const releaseApp = express();
    releaseApp.use('/api', createHealthRouter(readyStore, resolveRuntimeReleaseId(manifestPath)));
    const releaseSrv = http.createServer(releaseApp);
    await new Promise<void>((resolve) => releaseSrv.listen(0, '127.0.0.1', resolve));
    try {
      const addr = releaseSrv.address();
      if (!addr || typeof addr === 'string') {
        throw new Error('Unexpected address');
      }
      const relRes = await fetch(`http://127.0.0.1:${addr.port}/api/health`);
      assert.equal(relRes.status, 200);
      assert.equal(relRes.headers.get('x-app-release'), '2.4.1');
      const relBody = (await relRes.json()) as { status: string; releaseId?: string; gitCommit?: string };
      assert.equal(relBody.status, 'UP');
      assert.equal(relBody.releaseId, '2.4.1');
      assert.equal(relBody.gitCommit, undefined);
    } finally {
      await new Promise<void>((resolve, reject) => releaseSrv.close((err) => (err ? reject(err) : resolve())));
    }
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});
