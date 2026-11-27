import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { z } from 'zod';
import { AnalyzerMetrics, StoredAnalysisResults } from '../types/analysis';
import { NotFoundError, ValidationError } from '../utils/errors';
import { RawArtifactBundle } from './jenkinsClient';

const MAX_METRICS_BYTES = 5 * 1024 * 1024;
const MAX_SUMMARY_BYTES = 2 * 1024 * 1024;
const MAX_CHART_BYTES = 10 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export const CHART_FILE_NAMES = ['commits_per_author.png', 'daily_commit_activity.png'] as const;
export type ChartFileName = (typeof CHART_FILE_NAMES)[number];

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const AnalyzerTopRiskSchema = z.object({
  file: z.string().min(1),
  topAuthor: z.string().min(1),
  doa: z.number().finite(),
  firstAuthor: z.string().min(1),
  dl: z.number().finite().int().nonnegative(),
  ac: z.number().finite().int().nonnegative(),
  share: z.number().finite().min(0).max(1),
  riskLevel: z.string().min(1),
  commits: z.number().finite().int().positive(),
});

const AnalyzerAuthorSummarySchema = z.object({
  author: z.string().min(1),
  fileCount: z.number().finite().int().positive(),
  averageDoa: z.number().finite(),
  maxDoa: z.number().finite(),
});

const AnalyzerHotspotEntrySchema = z.object({
  file: z.string().min(1),
  additions: z.number().finite().int().nonnegative(),
  deletions: z.number().finite().int().nonnegative(),
  loc: z.number().finite().int().nonnegative(),
  commitCount: z.number().finite().int().nonnegative(),
  daysSinceChange: z.number().finite().int().nonnegative(),
  churn: z.number().finite().nonnegative(),
  hotspotScore: z.number().finite().nonnegative(),
});

const AnalyzerStaleBranchSchema = z.object({
  branch: z.string().min(1),
  daysSinceDivergence: z.number().finite().int().nonnegative(),
  mainCommitsSince: z.number().finite().int().nonnegative(),
  syncCommits: z.number().finite().int().nonnegative(),
  drift: z.number().finite().nonnegative(),
  riskLevel: z.string().min(1),
});

export const AnalyzerMetricsSchema = z.object({
  generatedAt: z.string().min(1),
  repository: z.object({
    mainBranch: z.string().min(1),
    trackedFiles: z.number().finite().int().nonnegative().optional(),
    commitHistoryAvailable: z.boolean(),
  }),
  busFactor: z.object({
    formula: z.string().min(1),
    threshold: z.number().finite(),
    filesAnalyzed: z.number().finite().int().nonnegative(),
    criticalFileCount: z.number().finite().int().nonnegative(),
    topRisk: AnalyzerTopRiskSchema.nullable(),
    criticalFiles: z.array(AnalyzerTopRiskSchema),
    highRiskFiles: z.array(AnalyzerTopRiskSchema),
    authorSummary: z.array(AnalyzerAuthorSummarySchema),
  }),
  hotspots: z.object({
    windowDays: z.number().finite().int().positive(),
    decayLambda: z.number().finite().nonnegative(),
    totalLoc: z.number().finite().int().nonnegative(),
    totalInsertions: z.number().finite().int().nonnegative(),
    totalDeletions: z.number().finite().int().nonnegative(),
    topHotspots: z.array(AnalyzerHotspotEntrySchema),
  }),
  branchDrift: z.object({
    mainBranch: z.string().min(1),
    branchesAnalyzed: z.number().finite().int().nonnegative(),
    staleBranches: z.array(AnalyzerStaleBranchSchema),
  }),
});

export class ArtifactValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ArtifactValidationError';
  }
}

export function isValidChartFileName(rawName: string): rawName is ChartFileName {
  return (CHART_FILE_NAMES as readonly string[]).includes(rawName);
}

export function isValidPngBuffer(buf: Buffer): boolean {
  return buf.length >= PNG_MAGIC.length && buf.length <= MAX_CHART_BYTES && buf.subarray(0, 8).equals(PNG_MAGIC);
}

export function assertValidAnalysisUuid(rawId: string): void {
  if (!UUID_V4_REGEX.test(rawId)) {
    throw new ValidationError('Invalid analysisId format; expected UUID v4');
  }
}

/**
 * Isolated analyzer artifact validator and local disk cache.
 * Validates metrics JSON schemas, Markdown report text, and PNG headers before
 * persisting results under <dataDir>/artifacts/<analysisId>/.
 * Never executes downloaded artifacts or uses unvalidated path segments.
 */
export class ArtifactIngestor {
  public readonly artifactsRootDir: string;

  constructor(dataDir: string) {
    this.artifactsRootDir = path.join(path.resolve(dataDir), 'artifacts');
  }

  public async ingestAndCache(analysisId: string, bundle: RawArtifactBundle): Promise<StoredAnalysisResults> {
    assertValidAnalysisUuid(analysisId);

    const metrics = this.parseAndValidateMetrics(bundle.metricsJson);
    const summaryMarkdown = this.parseAndValidateSummary(bundle.summaryMarkdown);

    const hasCommits = metrics.repository.commitHistoryAvailable;

    if (hasCommits) {
      if (bundle.commitsPerAuthorPng === null) {
        throw new ArtifactValidationError('Missing required chart artifact: commits_per_author.png');
      }
      if (bundle.dailyActivityPng === null) {
        throw new ArtifactValidationError('Missing required chart artifact: daily_commit_activity.png');
      }
    }

    if (bundle.commitsPerAuthorPng !== null && !isValidPngBuffer(bundle.commitsPerAuthorPng)) {
      throw new ArtifactValidationError('Artifact commits_per_author.png is not a valid PNG or exceeds size limits');
    }
    if (bundle.dailyActivityPng !== null && !isValidPngBuffer(bundle.dailyActivityPng)) {
      throw new ArtifactValidationError('Artifact daily_commit_activity.png is not a valid PNG or exceeds size limits');
    }

    const analysisDir = path.join(this.artifactsRootDir, analysisId);
    await fs.mkdir(analysisDir, { recursive: true, mode: 0o750 });

    if (bundle.commitsPerAuthorPng !== null) {
      await this.writeAtomicFile(path.join(analysisDir, 'commits_per_author.png'), bundle.commitsPerAuthorPng);
    }
    if (bundle.dailyActivityPng !== null) {
      await this.writeAtomicFile(path.join(analysisDir, 'daily_commit_activity.png'), bundle.dailyActivityPng);
    }

    const baseChartUrl = `/api/analyses/${analysisId}/charts`;
    return {
      metrics,
      summaryMarkdown,
      charts: {
        commitsPerAuthor:
          bundle.commitsPerAuthorPng !== null ? `${baseChartUrl}/commits_per_author.png` : null,
        dailyActivity:
          bundle.dailyActivityPng !== null ? `${baseChartUrl}/daily_commit_activity.png` : null,
      },
    };
  }

  public async readCachedChart(analysisId: string, chartName: string): Promise<Buffer> {
    assertValidAnalysisUuid(analysisId);

    if (!isValidChartFileName(chartName)) {
      throw new ValidationError(
        `Invalid chart name "${chartName}". Permitted values: ${CHART_FILE_NAMES.join(', ')}`,
      );
    }

    const fixedFilename: ChartFileName =
      chartName === 'commits_per_author.png' ? 'commits_per_author.png' : 'daily_commit_activity.png';
    const chartPath = path.join(this.artifactsRootDir, analysisId, fixedFilename);

    let buffer: Buffer;
    try {
      buffer = await fs.readFile(chartPath);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
        throw new NotFoundError(`Chart artifact "${fixedFilename}" is not available for analysis "${analysisId}"`);
      }
      throw new Error('Failed to load cached chart artifact');
    }

    if (!isValidPngBuffer(buffer)) {
      throw new ArtifactValidationError('Cached chart artifact failed PNG integrity validation');
    }

    return buffer;
  }

  private parseAndValidateMetrics(raw: Buffer): AnalyzerMetrics {
    if (raw.length === 0) {
      throw new ArtifactValidationError('Artifact metrics.json is empty');
    }
    if (raw.length > MAX_METRICS_BYTES) {
      throw new ArtifactValidationError(`Artifact metrics.json exceeds maximum size (${MAX_METRICS_BYTES} bytes)`);
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(raw.toString('utf8'));
    } catch (err) {
      throw new ArtifactValidationError(
        `Artifact metrics.json contains invalid JSON: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    const parsed = AnalyzerMetricsSchema.safeParse(decoded);
    if (!parsed.success) {
      const issues = parsed.error.issues.map((i) => `${i.path.join('.') || 'root'}: ${i.message}`).join('; ');
      throw new ArtifactValidationError(`Artifact metrics.json failed schema validation: ${issues}`);
    }

    return parsed.data;
  }

  private parseAndValidateSummary(raw: Buffer): string {
    if (raw.length === 0) {
      throw new ArtifactValidationError('Artifact summary.md is empty');
    }
    if (raw.length > MAX_SUMMARY_BYTES) {
      throw new ArtifactValidationError(`Artifact summary.md exceeds maximum size (${MAX_SUMMARY_BYTES} bytes)`);
    }
    if (raw.includes(0x00)) {
      throw new ArtifactValidationError('Artifact summary.md contains invalid NUL bytes');
    }

    const text = raw.toString('utf8');
    if (text.trim().length === 0) {
      throw new ArtifactValidationError('Artifact summary.md contains no readable text');
    }
    return text;
  }

  private async writeAtomicFile(targetPath: string, data: Buffer): Promise<void> {
    const dir = path.dirname(targetPath);
    const tmpPath = path.join(dir, `.tmp.${process.pid}.${randomUUID()}`);
    const handle = await fs.open(tmpPath, 'w', 0o640);
    try {
      await handle.writeFile(data);
      await handle.sync();
    } catch (err) {
      await handle.close().catch(() => undefined);
      await fs.rm(tmpPath, { force: true }).catch(() => undefined);
      throw err;
    }
    await handle.close();
    try {
      await fs.rename(tmpPath, targetPath);
    } catch (err) {
      await fs.rm(tmpPath, { force: true }).catch(() => undefined);
      throw err;
    }
  }
}
