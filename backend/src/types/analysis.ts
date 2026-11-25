export type AnalysisStatus =
  | 'QUEUED'
  | 'BUILDING'
  | 'COMPLETED'
  | 'FAILED'
  | 'CANCELLED';

export interface AnalysisErrorInfo {
  code: string;
  message: string;
}

export interface AnalyzerTopRisk {
  file: string;
  topAuthor: string;
  doa: number;
  firstAuthor: string;
  dl: number;
  ac: number;
  share: number;
  riskLevel: 'critical' | 'high' | 'moderate' | string;
  commits: number;
}

export interface AnalyzerAuthorSummary {
  author: string;
  fileCount: number;
  averageDoa: number;
  maxDoa: number;
}

export interface AnalyzerHotspotEntry {
  file: string;
  additions: number;
  deletions: number;
  loc: number;
  commitCount: number;
  daysSinceChange: number;
  churn: number;
  hotspotScore: number;
}

export interface AnalyzerStaleBranchEntry {
  branch: string;
  daysSinceDivergence: number;
  mainCommitsSince: number;
  syncCommits: number;
  drift: number;
  riskLevel: 'critical' | 'high' | 'moderate' | string;
}

/**
 * Exact output schema emitted by ai/metrics.js (reports/metrics.json).
 */
export interface AnalyzerMetrics {
  generatedAt: string;
  repository: {
    mainBranch: string;
    trackedFiles?: number | undefined;
    commitHistoryAvailable: boolean;
  };
  busFactor: {
    formula: string;
    threshold: number;
    filesAnalyzed: number;
    criticalFileCount: number;
    topRisk: AnalyzerTopRisk | null;
    criticalFiles: AnalyzerTopRisk[];
    highRiskFiles: AnalyzerTopRisk[];
    authorSummary: AnalyzerAuthorSummary[];
  };
  hotspots: {
    windowDays: number;
    decayLambda: number;
    totalLoc: number;
    totalInsertions: number;
    totalDeletions: number;
    topHotspots: AnalyzerHotspotEntry[];
  };
  branchDrift: {
    mainBranch: string;
    branchesAnalyzed: number;
    staleBranches: AnalyzerStaleBranchEntry[];
  };
}

export interface AnalysisChartsMap {
  commitsPerAuthor: string | null;
  dailyActivity: string | null;
}

export interface StoredAnalysisResults {
  metrics: AnalyzerMetrics | Record<string, unknown>;
  summaryMarkdown: string;
  charts: AnalysisChartsMap;
}

/**
 * Internal persisted record mapped cleanly away from public API responses.
 */
export interface AnalysisRecord {
  analysisId: string;
  repositoryUrl: string;
  status: AnalysisStatus;
  progress: string;
  createdAt: string;
  updatedAt: string;
  error: AnalysisErrorInfo | null;
  queueId: number | null;
  buildNumber: number | null;
  results: StoredAnalysisResults | null;
}

/**
 * Public status contract returned by GET /api/analyses/:id (zero Jenkins internal IDs).
 */
export interface AnalysisPublicStatus {
  analysisId: string;
  status: AnalysisStatus;
  progress: string;
  createdAt: string;
  updatedAt: string;
  error: AnalysisErrorInfo | null;
}

/**
 * Public acceptance contract returned by POST /api/analyses (HTTP 202).
 */
export interface AnalysisAcceptedResponse {
  analysisId: string;
  status: 'QUEUED';
  createdAt: string;
}

/**
 * Public results contract returned by GET /api/analyses/:id/results (HTTP 200).
 */
export interface AnalysisResultsResponse {
  analysisId: string;
  repositoryUrl: string;
  status: 'COMPLETED';
  createdAt: string;
  updatedAt: string;
  metrics: AnalyzerMetrics | Record<string, unknown>;
  summaryMarkdown: string;
  charts: AnalysisChartsMap;
}

export function toPublicStatus(record: AnalysisRecord): AnalysisPublicStatus {
  return {
    analysisId: record.analysisId,
    status: record.status,
    progress: record.progress,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    error: record.error,
  };
}

export function toPublicResults(record: AnalysisRecord): AnalysisResultsResponse {
  if (record.status !== 'COMPLETED' || record.results === null) {
    throw new Error('Cannot convert incomplete analysis record into public results');
  }
  return {
    analysisId: record.analysisId,
    repositoryUrl: record.repositoryUrl,
    status: 'COMPLETED',
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    metrics: record.results.metrics,
    summaryMarkdown: record.results.summaryMarkdown,
    charts: record.results.charts,
  };
}
