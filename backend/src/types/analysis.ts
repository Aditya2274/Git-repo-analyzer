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

export interface AnalysisChartsMap {
  commitsPerAuthor: string | null;
  dailyActivity: string | null;
}

export interface StoredAnalysisResults {
  metrics: Record<string, unknown>;
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
