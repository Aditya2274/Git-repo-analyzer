import { AnalyzerMetrics } from '../types/analysis';
import {
  IJenkinsClient,
  JenkinsBuildResult,
  JenkinsBuildStatus,
  JenkinsQueueResolution,
  JenkinsTriggerResult,
  RawArtifactBundle,
} from './jenkinsClient';

export type MockScenario =
  | 'success'
  | 'fail'
  | 'cancel'
  | 'zero_commits'
  | 'missing_chart'
  | 'bad_metrics'
  | 'dispatch_error';

export interface MockJenkinsClientOptions {
  queueDelayMs?: number;
  buildDelayMs?: number;
  now?: () => number;
  scenarioResolver?: (repositoryUrl: string) => MockScenario;
}

interface MockJobState {
  queueId: number;
  buildNumber: number;
  repositoryUrl: string;
  scenario: MockScenario;
  queuedAtMs: number;
}

// Valid 1x1 white PNG image (magic header + IHDR + zlib IDAT + IEND with valid CRCs)
const SAMPLE_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2ZkAAAAASUVORK5CYII=';

export function createSamplePngBuffer(): Buffer {
  return Buffer.from(SAMPLE_PNG_BASE64, 'base64');
}

export function buildSampleMetrics(repositoryUrl: string, zeroCommits = false): AnalyzerMetrics {
  const generatedAt = '2026-11-25T10:00:00.000Z';

  if (zeroCommits) {
    return {
      generatedAt,
      repository: {
        mainBranch: 'main',
        commitHistoryAvailable: false,
      },
      busFactor: {
        formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
        threshold: 4.25,
        filesAnalyzed: 0,
        criticalFileCount: 0,
        topRisk: null,
        criticalFiles: [],
        highRiskFiles: [],
        authorSummary: [],
      },
      hotspots: {
        windowDays: 30,
        decayLambda: 0.05,
        totalLoc: 0,
        totalInsertions: 0,
        totalDeletions: 0,
        topHotspots: [],
      },
      branchDrift: {
        mainBranch: 'main',
        branchesAnalyzed: 0,
        staleBranches: [],
      },
    };
  }

  const topRisk = {
    file: 'src/core/engine.ts',
    topAuthor: 'Alice Developer',
    doa: 4.791,
    firstAuthor: 'Alice Developer',
    dl: 9,
    ac: 2,
    share: 0.818,
    riskLevel: 'critical',
    commits: 11,
  };

  return {
    generatedAt,
    repository: {
      mainBranch: 'main',
      trackedFiles: 28,
      commitHistoryAvailable: true,
    },
    busFactor: {
      formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
      threshold: 4.25,
      filesAnalyzed: 28,
      criticalFileCount: 1,
      topRisk,
      criticalFiles: [topRisk],
      highRiskFiles: [
        topRisk,
        {
          file: 'src/api/router.ts',
          topAuthor: 'Bob Maintainer',
          doa: 3.91,
          firstAuthor: 'Bob Maintainer',
          dl: 5,
          ac: 3,
          share: 0.625,
          riskLevel: 'high',
          commits: 8,
        },
      ],
      authorSummary: [
        { author: 'Alice Developer', fileCount: 18, averageDoa: 4.12, maxDoa: 4.791 },
        { author: 'Bob Maintainer', fileCount: 10, averageDoa: 3.45, maxDoa: 3.91 },
      ],
    },
    hotspots: {
      windowDays: 30,
      decayLambda: 0.05,
      totalLoc: 2450,
      totalInsertions: 680,
      totalDeletions: 215,
      topHotspots: [
        {
          file: 'src/core/engine.ts',
          additions: 320,
          deletions: 95,
          loc: 410,
          commitCount: 6,
          daysSinceChange: 2,
          churn: 101.22,
          hotspotScore: 549.5,
        },
        {
          file: 'src/api/router.ts',
          additions: 140,
          deletions: 40,
          loc: 220,
          commitCount: 4,
          daysSinceChange: 5,
          churn: 81.818,
          hotspotScore: 254.9,
        },
      ],
    },
    branchDrift: {
      mainBranch: 'main',
      branchesAnalyzed: 2,
      staleBranches: [
        {
          branch: 'feature/legacy-export',
          daysSinceDivergence: 38,
          mainCommitsSince: 14,
          syncCommits: 0,
          drift: 532,
          riskLevel: 'critical',
        },
      ],
    },
  };
}

export function buildSampleMarkdown(repositoryUrl: string, zeroCommits = false): string {
  if (zeroCommits) {
    return [
      '# Git Repository Analysis Report',
      '',
      `Target: ${repositoryUrl}`,
      '',
      '**No commits found — charts will be skipped.**',
      '',
      '## Deterministic Metric Summary',
      '- Main branch: main',
      '- Tracked files analyzed: 0',
      '- Bus factor formula: DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
      '- Branches analyzed: 0',
    ].join('\n');
  }

  return [
    '# AI Architectural Repository Analysis',
    '',
    `Simulated local analysis report for \`${repositoryUrl}\`.`,
    '',
    '## 1. Velocity & Maintenance Momentum',
    '- Development activity remains steady across core engine and API routing modules.',
    '',
    '## 2. Contributor Dynamics & Bus Factor',
    '- `src/core/engine.ts` exhibits concentrated authorship (DOA 4.791, share 81.8%).',
    '',
    '## 3. Code Churn & Hotspot Analysis',
    '- Recent 30-day churn totals 680 insertions and 215 deletions across 2,450 LOC.',
    '',
    '## 4. Repository Hygiene & Recommendations',
    '- `feature/legacy-export` shows high drift (532) and should be rebased or archived.',
    '',
    '## 5. Summary',
    '- Total Commits: 24',
    '- Commits last 7 days: 6',
    '- Commits last 30 days: 15',
  ].join('\n');
}

/**
 * Deterministic mock Jenkins client for local development and automated tests.
 * Defaults to a 2s queue delay and 5s build delay (matching IMPLEMENTATION_PLAN.md).
 */
export class MockJenkinsClient implements IJenkinsClient {
  private readonly queueDelayMs: number;
  private readonly buildDelayMs: number;
  private readonly now: () => number;
  private readonly scenarioResolver: (repositoryUrl: string) => MockScenario;

  private nextQueueId = 100;
  private nextBuildNumber = 1;
  private readonly jobsByQueue = new Map<number, MockJobState>();
  private readonly jobsByBuild = new Map<number, MockJobState>();

  constructor(options: MockJenkinsClientOptions = {}) {
    this.queueDelayMs = options.queueDelayMs ?? 2000;
    this.buildDelayMs = options.buildDelayMs ?? 5000;
    this.now = options.now ?? (() => Date.now());
    this.scenarioResolver = options.scenarioResolver ?? (() => 'success');
  }

  public async triggerJob(repositoryUrl: string): Promise<JenkinsTriggerResult> {
    const scenario = this.scenarioResolver(repositoryUrl);
    if (scenario === 'dispatch_error') {
      throw new Error('Simulated Jenkins controller connection refused');
    }

    const queueId = this.nextQueueId;
    const buildNumber = this.nextBuildNumber;
    this.nextQueueId += 1;
    this.nextBuildNumber += 1;

    const job: MockJobState = {
      queueId,
      buildNumber,
      repositoryUrl,
      scenario,
      queuedAtMs: this.now(),
    };
    this.jobsByQueue.set(queueId, job);
    this.jobsByBuild.set(buildNumber, job);

    return { queueId };
  }

  public async getBuildFromQueue(queueId: number): Promise<JenkinsQueueResolution> {
    const job = this.jobsByQueue.get(queueId);
    if (!job) {
      throw new Error(`Unknown mock Jenkins queue item ${queueId}`);
    }

    const elapsed = this.now() - job.queuedAtMs;
    if (elapsed < this.queueDelayMs) {
      return { resolved: false, cancelled: false, buildNumber: null };
    }

    if (job.scenario === 'cancel') {
      return { resolved: true, cancelled: true, buildNumber: null };
    }

    return { resolved: true, cancelled: false, buildNumber: job.buildNumber };
  }

  public async getBuildStatus(buildNumber: number): Promise<JenkinsBuildStatus> {
    const job = this.jobsByBuild.get(buildNumber);
    if (!job) {
      throw new Error(`Unknown mock Jenkins build #${buildNumber}`);
    }

    const buildElapsed = this.now() - (job.queuedAtMs + this.queueDelayMs);
    if (buildElapsed < this.buildDelayMs) {
      return { building: true, result: null, durationMs: null };
    }

    if (job.scenario === 'fail') {
      return { building: false, result: 'FAILURE', durationMs: this.buildDelayMs };
    }
    if (job.scenario === 'cancel') {
      return { building: false, result: 'ABORTED', durationMs: this.buildDelayMs };
    }

    return { building: false, result: 'SUCCESS', durationMs: this.buildDelayMs };
  }

  public async getBuildResult(buildNumber: number): Promise<JenkinsBuildResult> {
    const job = this.jobsByBuild.get(buildNumber);
    if (!job) {
      throw new Error(`Unknown mock Jenkins build #${buildNumber}`);
    }

    const status = await this.getBuildStatus(buildNumber);
    if (status.building || status.result !== 'SUCCESS') {
      return {
        ...status,
        artifacts: [],
      };
    }

    if (job.scenario === 'zero_commits') {
      return {
        ...status,
        artifacts: [
          { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
          { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
        ],
      };
    }

    if (job.scenario === 'missing_chart') {
      return {
        ...status,
        artifacts: [
          { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
          { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
          { fileName: 'commits_per_author.png', relativePath: 'target-repo/reports/charts/commits_per_author.png' },
        ],
      };
    }

    return {
      ...status,
      artifacts: [
        { fileName: 'metrics.json', relativePath: 'target-repo/reports/metrics.json' },
        { fileName: 'summary.md', relativePath: 'target-repo/reports/summary.md' },
        { fileName: 'commits_per_author.png', relativePath: 'target-repo/reports/charts/commits_per_author.png' },
        { fileName: 'daily_commit_activity.png', relativePath: 'target-repo/reports/charts/daily_commit_activity.png' },
      ],
    };
  }

  public async fetchArtifact(buildNumber: number): Promise<RawArtifactBundle> {
    const job = this.jobsByBuild.get(buildNumber);
    if (!job) {
      throw new Error(`Unknown mock Jenkins build #${buildNumber}`);
    }

    if (job.scenario === 'bad_metrics') {
      return {
        metricsJson: Buffer.from('{invalid-metrics', 'utf8'),
        summaryMarkdown: Buffer.from(buildSampleMarkdown(job.repositoryUrl, false), 'utf8'),
        commitsPerAuthorPng: createSamplePngBuffer(),
        dailyActivityPng: createSamplePngBuffer(),
      };
    }

    if (job.scenario === 'zero_commits') {
      return {
        metricsJson: Buffer.from(JSON.stringify(buildSampleMetrics(job.repositoryUrl, true), null, 2), 'utf8'),
        summaryMarkdown: Buffer.from(buildSampleMarkdown(job.repositoryUrl, true), 'utf8'),
        commitsPerAuthorPng: null,
        dailyActivityPng: null,
      };
    }

    if (job.scenario === 'missing_chart') {
      return {
        metricsJson: Buffer.from(JSON.stringify(buildSampleMetrics(job.repositoryUrl, false), null, 2), 'utf8'),
        summaryMarkdown: Buffer.from(buildSampleMarkdown(job.repositoryUrl, false), 'utf8'),
        commitsPerAuthorPng: createSamplePngBuffer(),
        dailyActivityPng: null,
      };
    }

    return {
      metricsJson: Buffer.from(JSON.stringify(buildSampleMetrics(job.repositoryUrl, false), null, 2), 'utf8'),
      summaryMarkdown: Buffer.from(buildSampleMarkdown(job.repositoryUrl, false), 'utf8'),
      commitsPerAuthorPng: createSamplePngBuffer(),
      dailyActivityPng: createSamplePngBuffer(),
    };
  }
}
