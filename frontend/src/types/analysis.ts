export type AnalysisStatus =
  | 'QUEUED'
  | 'BUILDING'
  | 'COMPLETED'
  | 'FAILED'
  | 'CANCELLED';

export interface HealthResponse {
  status: 'UP' | string;
  timestamp: string;
}

export interface AnalysisErrorInfo {
  code: string;
  message: string;
}

export interface ApiErrorPayload {
  error: {
    code: string;
    message: string;
    details: unknown;
  };
}

export interface AnalysisAcceptedResponse {
  analysisId: string;
  status: 'QUEUED';
  createdAt: string;
}

export interface AnalysisPublicStatus {
  analysisId: string;
  status: AnalysisStatus;
  progress: string;
  createdAt: string;
  updatedAt: string;
  error: AnalysisErrorInfo | null;
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

export interface AnalyzerMetrics {
  generatedAt: string;
  repository: {
    mainBranch: string;
    trackedFiles?: number;
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

export interface AnalysisResultsResponse {
  analysisId: string;
  repositoryUrl: string;
  status: 'COMPLETED';
  createdAt: string;
  updatedAt: string;
  metrics: AnalyzerMetrics;
  summaryMarkdown: string;
  charts: AnalysisChartsMap;
}

export interface SessionHistoryItem {
  analysisId: string;
  repositoryUrl: string;
  createdAt: string;
  lastStatus: AnalysisStatus;
}

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isValidUuidV4(value: string): boolean {
  return UUID_V4_REGEX.test(value.trim());
}

export function isTerminalStatus(status: AnalysisStatus): boolean {
  return status === 'COMPLETED' || status === 'FAILED' || status === 'CANCELLED';
}

export function formatRepositorySlug(repositoryUrl: string): string {
  try {
    const parsed = new URL(repositoryUrl);
    return parsed.pathname.replace(/^\/+|\/+$/g, '') || repositoryUrl;
  } catch {
    return repositoryUrl;
  }
}

export function formatUtcTimestamp(iso: string): string {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) {
    return iso;
  }
  return new Date(ms).toLocaleString();
}
