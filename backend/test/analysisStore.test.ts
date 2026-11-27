import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import fsPromises from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { FileAnalysisStore } from '../src/services/analysisStore';
import { AnalysisRecord } from '../src/types/analysis';

function makeRecord(overrides: Partial<AnalysisRecord> = {}): AnalysisRecord {
  const now = '2026-11-25T10:00:00.000Z';
  return {
    analysisId: randomUUID(),
    repositoryUrl: 'https://github.com/octocat/Hello-World',
    status: 'COMPLETED',
    progress: 'Analysis completed',
    createdAt: now,
    updatedAt: now,
    error: null,
    queueId: 12,
    buildNumber: 4,
    results: {
      metrics: { repository: { mainBranch: 'main' } },
      summaryMarkdown: '# Report',
      charts: {
        commitsPerAuthor: '/api/analyses/test/charts/commits_per_author.png',
        dailyActivity: '/api/analyses/test/charts/daily_commit_activity.png',
      },
    },
    ...overrides,
  };
}

test('FileAnalysisStore persists completed state across simulated restarts and enforces recovery rules', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'git-repo-store-'));
  try {
    const store1 = new FileAnalysisStore(dataDir);
    const initSummary1 = await store1.initialize();
    assert.equal(initSummary1.totalLoaded, 0);

    const completedRec = makeRecord({ status: 'COMPLETED' });
    const queuedNoHandle = makeRecord({
      status: 'QUEUED',
      progress: 'Dispatching...',
      queueId: null,
      buildNumber: null,
      results: null,
    });
    const buildingWithHandle = makeRecord({
      status: 'BUILDING',
      progress: 'Running Docker container...',
      queueId: 44,
      buildNumber: 8,
      results: null,
      createdAt: '2026-11-25T10:09:00.000Z',
    });
    const staleInFlight = makeRecord({
      status: 'BUILDING',
      progress: 'Stuck build...',
      queueId: 11,
      buildNumber: 2,
      results: null,
      createdAt: '2026-11-25T09:00:00.000Z', // 70m old -> exceeds 10m ceiling
    });

    await store1.save(completedRec);
    await store1.save(queuedNoHandle);
    await store1.save(buildingWithHandle);
    await store1.save(staleInFlight);

    // Place an orphan temp file to confirm cleanup on restart
    await fsPromises.writeFile(path.join(dataDir, '.analyses.json.tmp.orphan'), 'stale', 'utf8');

    // Simulate backend restart by loading brand-new FileAnalysisStore
    const store2 = new FileAnalysisStore(dataDir);
    const recovery = await store2.initialize({
      maxInFlightAgeMs: 600_000,
      now: () => new Date('2026-11-25T10:10:00.000Z'),
    });

    assert.equal(recovery.totalLoaded, 4);
    assert.equal(recovery.preservedCompleted, 1);
    assert.equal(recovery.recoveredInFlight, 1);
    assert.equal(recovery.failedInterrupted, 2);

    assert.deepEqual(store2.getById(completedRec.analysisId), completedRec);

    const recoveredNoHandle = store2.getById(queuedNoHandle.analysisId);
    assert.equal(recoveredNoHandle?.status, 'FAILED');
    assert.equal(recoveredNoHandle?.error?.code, 'INTERRUPTED_ON_RESTART');

    const recoveredStale = store2.getById(staleInFlight.analysisId);
    assert.equal(recoveredStale?.status, 'FAILED');
    assert.equal(recoveredStale?.error?.code, 'STALE_ON_RESTART');

    const resumable = store2.listResumableInFlight();
    assert.equal(resumable.length, 1);
    assert.equal(resumable[0]?.analysisId, buildingWithHandle.analysisId);

    const filesAfter = await fsPromises.readdir(dataDir);
    assert.deepEqual(filesAfter, ['analyses.json']);
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});

test('FileAnalysisStore serializes concurrent writes and preserves prior state when atomic rename fails', async (t) => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'git-repo-atomic-'));
  try {
    const store = new FileAnalysisStore(dataDir);
    await store.initialize();

    // Concurrent writes must all survive cleanly without dropping updates
    const batch = Array.from({ length: 12 }, (_, idx) =>
      makeRecord({ progress: `Concurrent record ${idx}` }),
    );
    await Promise.all(batch.map((record) => store.save(record)));
    assert.equal(store.listAll().length, 12);

    const firstId = batch[0]!.analysisId;
    await store.update(firstId, (cur) => ({
      ...cur,
      progress: 'Updated atomically',
      updatedAt: '2026-11-25T10:20:00.000Z',
    }));

    const baselineDisk = await fsPromises.readFile(store.stateFilePath, 'utf8');

    // Simulate OS failure during atomic rename; disk file and temp cleanup must remain intact
    const renameMock = t.mock.method(fsPromises, 'rename', async () => {
      throw new Error('EIO simulated disk failure');
    });

    await assert.rejects(() => store.save(makeRecord()), /EIO simulated disk failure/);
    renameMock.mock.restore();

    const afterFailureDisk = await fsPromises.readFile(store.stateFilePath, 'utf8');
    assert.equal(afterFailureDisk, baselineDisk, 'Original analyses.json must remain untouched on failed write');

    const entries = await fsPromises.readdir(dataDir);
    assert.deepEqual(entries, ['analyses.json'], 'Failed atomic write must remove temporary file');
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});

test('FileAnalysisStore fails explicitly when analyses.json is corrupted rather than wiping data', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'git-repo-corrupt-'));
  try {
    await fsPromises.writeFile(path.join(dataDir, 'analyses.json'), '{not-valid-json', 'utf8');
    const store = new FileAnalysisStore(dataDir);
    await assert.rejects(() => store.initialize(), /Corrupt analysis store JSON/);
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});
