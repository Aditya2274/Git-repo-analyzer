import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fsPromises from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { ArtifactIngestor, ArtifactValidationError } from '../src/services/artifactIngestion';
import { buildSampleMarkdown, buildSampleMetrics, createSamplePngBuffer } from '../src/services/mockJenkinsClient';
import { NotFoundError, ValidationError } from '../src/utils/errors';

test('ArtifactIngestor validates, caches PNGs non-executably, and enforces completeness cleanly', async () => {
  const dataDir = await fsPromises.mkdtemp(path.join(os.tmpdir(), 'artifact-ingest-'));
  try {
    const ingestor = new ArtifactIngestor(dataDir);
    const id = randomUUID();
    const validMetrics = Buffer.from(
      JSON.stringify(buildSampleMetrics('https://github.com/octocat/Hello-World')),
      'utf8',
    );
    const validSummary = Buffer.from(buildSampleMarkdown('https://github.com/octocat/Hello-World'), 'utf8');
    const validPng = createSamplePngBuffer();

    const stored = await ingestor.ingestAndCache(id, {
      metricsJson: validMetrics,
      summaryMarkdown: validSummary,
      commitsPerAuthorPng: validPng,
      dailyActivityPng: validPng,
    });

    assert.equal(stored.charts.commitsPerAuthor, `/api/analyses/${id}/charts/commits_per_author.png`);
    assert.equal(stored.charts.dailyActivity, `/api/analyses/${id}/charts/daily_commit_activity.png`);

    const loadedAuthorPng = await ingestor.readCachedChart(id, 'commits_per_author.png');
    assert.ok(loadedAuthorPng.equals(validPng));

    const stat = await fsPromises.stat(path.join(dataDir, 'artifacts', id, 'commits_per_author.png'));
    assert.equal(stat.mode & 0o111, 0, 'Cached artifact files must never have executable bits');

    // Missing chart on non-zero-commit repo MUST fail (never fabricate or silently succeed)
    await assert.rejects(
      () =>
        ingestor.ingestAndCache(randomUUID(), {
          metricsJson: validMetrics,
          summaryMarkdown: validSummary,
          commitsPerAuthorPng: validPng,
          dailyActivityPng: null,
        }),
      /Missing required chart artifact: daily_commit_activity\.png/,
    );

    // Zero-commit repository omits charts legitimately
    const zeroId = randomUUID();
    const zeroStored = await ingestor.ingestAndCache(zeroId, {
      metricsJson: Buffer.from(
        JSON.stringify(buildSampleMetrics('https://github.com/octocat/Empty', true)),
        'utf8',
      ),
      summaryMarkdown: Buffer.from(buildSampleMarkdown('https://github.com/octocat/Empty', true), 'utf8'),
      commitsPerAuthorPng: null,
      dailyActivityPng: null,
    });
    assert.equal(zeroStored.charts.commitsPerAuthor, null);
    assert.equal(zeroStored.charts.dailyActivity, null);
    await assert.rejects(() => ingestor.readCachedChart(zeroId, 'commits_per_author.png'), NotFoundError);

    // Invalid / spoofed payloads rejected
    await assert.rejects(
      () =>
        ingestor.ingestAndCache(randomUUID(), {
          metricsJson: Buffer.from('{"repository": {}}', 'utf8'),
          summaryMarkdown: validSummary,
          commitsPerAuthorPng: validPng,
          dailyActivityPng: validPng,
        }),
      ArtifactValidationError,
    );

    await assert.rejects(
      () =>
        ingestor.ingestAndCache(randomUUID(), {
          metricsJson: validMetrics,
          summaryMarkdown: Buffer.from('   \n  ', 'utf8'),
          commitsPerAuthorPng: validPng,
          dailyActivityPng: validPng,
        }),
      ArtifactValidationError,
    );

    await assert.rejects(
      () =>
        ingestor.ingestAndCache(randomUUID(), {
          metricsJson: validMetrics,
          summaryMarkdown: validSummary,
          commitsPerAuthorPng: Buffer.from('<script>alert(1)</script>', 'utf8'),
          dailyActivityPng: validPng,
        }),
      ArtifactValidationError,
    );

    await assert.rejects(() => ingestor.readCachedChart(id, '../secret.png'), ValidationError);
  } finally {
    await fsPromises.rm(dataDir, { recursive: true, force: true });
  }
});
