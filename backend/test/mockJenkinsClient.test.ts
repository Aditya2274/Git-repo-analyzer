import assert from 'node:assert/strict';
import test from 'node:test';
import { ArtifactIngestor } from '../src/services/artifactIngestion';
import { MockJenkinsClient, MockScenario } from '../src/services/mockJenkinsClient';
import fsPromises from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

test('MockJenkinsClient progresses deterministically through QUEUED -> BUILDING -> COMPLETED', async () => {
  let clockMs = 1_000_000;
  const mock = new MockJenkinsClient({
    queueDelayMs: 2000,
    buildDelayMs: 5000,
    now: () => clockMs,
  });

  const { queueId } = await mock.triggerJob('https://github.com/octocat/Hello-World');
  assert.ok(Number.isInteger(queueId));

  // Immediately queued -> unresolved
  const q1 = await mock.getBuildFromQueue(queueId);
  assert.deepEqual(q1, { resolved: false, cancelled: false, buildNumber: null });

  // Advance past queueDelayMs (2s) -> resolved to buildNumber
  clockMs += 2000;
  const q2 = await mock.getBuildFromQueue(queueId);
  assert.equal(q2.resolved, true);
  assert.equal(q2.cancelled, false);
  assert.ok(q2.buildNumber !== null);

  // Immediately after starting -> BUILDING
  const s1 = await mock.getBuildStatus(q2.buildNumber);
  assert.equal(s1.building, true);
  assert.equal(s1.result, null);

  // Advance past buildDelayMs (5s) -> COMPLETED (SUCCESS) + artifacts available
  clockMs += 5000;
  const s2 = await mock.getBuildStatus(q2.buildNumber);
  assert.equal(s2.building, false);
  assert.equal(s2.result, 'SUCCESS');

  const res = await mock.getBuildResult(q2.buildNumber);
  assert.equal(res.artifacts.length, 4);

  const bundle = await mock.fetchArtifact(q2.buildNumber);
  const tempDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'mock-ingestor-'));
  try {
    const ingestor = new ArtifactIngestor(tempDir);
    const ingested = await ingestor.ingestAndCache(randomUUID(), bundle);
    assert.equal(ingested.metrics.repository && typeof ingested.metrics.repository, 'object');
    assert.ok(ingested.summaryMarkdown.includes('AI Architectural Repository Analysis'));
    assert.ok(ingested.charts.commitsPerAuthor?.endsWith('/commits_per_author.png'));
    assert.ok(ingested.charts.dailyActivity?.endsWith('/daily_commit_activity.png'));
  } finally {
    await fsPromises.rm(tempDir, { recursive: true, force: true });
  }
});

test('MockJenkinsClient supports controlled FAILURE, CANCELLED, and zero-commit scenarios', async () => {
  let clockMs = 5_000_000;
  const scenarioMap: Record<string, MockScenario> = {
    'https://github.com/octocat/Fail-Repo': 'fail',
    'https://github.com/octocat/Cancel-Repo': 'cancel',
    'https://github.com/octocat/Empty-Repo': 'zero_commits',
  };

  const mock = new MockJenkinsClient({
    queueDelayMs: 100,
    buildDelayMs: 100,
    now: () => clockMs,
    scenarioResolver: (url) => scenarioMap[url] ?? 'success',
  });

  // Failure path
  const failDispatch = await mock.triggerJob('https://github.com/octocat/Fail-Repo');
  clockMs += 200;
  const failQ = await mock.getBuildFromQueue(failDispatch.queueId);
  assert.ok(failQ.buildNumber !== null);
  const failStatus = await mock.getBuildStatus(failQ.buildNumber);
  assert.equal(failStatus.building, false);
  assert.equal(failStatus.result, 'FAILURE');

  // Cancelled in queue path
  const cancelDispatch = await mock.triggerJob('https://github.com/octocat/Cancel-Repo');
  clockMs += 200;
  const cancelQ = await mock.getBuildFromQueue(cancelDispatch.queueId);
  assert.equal(cancelQ.cancelled, true);

  // Zero-commit repository omits chart PNGs cleanly
  const emptyDispatch = await mock.triggerJob('https://github.com/octocat/Empty-Repo');
  clockMs += 200;
  const emptyQ = await mock.getBuildFromQueue(emptyDispatch.queueId);
  assert.ok(emptyQ.buildNumber !== null);
  const emptyBundle = await mock.fetchArtifact(emptyQ.buildNumber);
  assert.equal(emptyBundle.commitsPerAuthorPng, null);
  assert.equal(emptyBundle.dailyActivityPng, null);

  await assert.rejects(() => mock.getBuildFromQueue(999999), /Unknown mock Jenkins queue item/);
  await assert.rejects(() => mock.getBuildStatus(999999), /Unknown mock Jenkins build/);
});
