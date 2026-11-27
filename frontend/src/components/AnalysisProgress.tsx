import React from 'react';
import { AnalysisPublicStatus, AnalysisStatus, formatUtcTimestamp } from '../types/analysis';

export interface AnalysisProgressProps {
  analysisId: string;
  repositoryUrl: string | null;
  statusData: AnalysisPublicStatus | null;
  isPolling: boolean;
  transientError: string | null;
  fatalError: string | null;
  timedOut: boolean;
  nextPollDelayMs: number;
  onRetryNow: () => void;
}

const STATUS_BADGE_STYLES: Record<AnalysisStatus, string> = {
  QUEUED: 'border-amber-200 bg-amber-50 text-amber-800',
  BUILDING: 'border-blue-200 bg-blue-50 text-blue-800',
  COMPLETED: 'border-emerald-200 bg-emerald-50 text-emerald-800',
  FAILED: 'border-red-200 bg-red-50 text-red-800',
  CANCELLED: 'border-slate-300 bg-slate-100 text-slate-700',
};

const STATUS_DESCRIPTIONS: Record<AnalysisStatus, string> = {
  QUEUED: 'Analysis request accepted and waiting for CI worker execution.',
  BUILDING: 'Containerized analyzer is cloning and evaluating Git history.',
  COMPLETED: 'Analysis completed and verified artifacts ingested.',
  FAILED: 'Analysis could not complete.',
  CANCELLED: 'Analysis job was cancelled before completion.',
};

export function AnalysisProgress({
  analysisId,
  repositoryUrl,
  statusData,
  isPolling,
  transientError,
  fatalError,
  timedOut,
  nextPollDelayMs,
  onRetryNow,
}: AnalysisProgressProps): React.ReactElement {
  const status: AnalysisStatus = statusData?.status ?? 'QUEUED';
  const badgeStyle = STATUS_BADGE_STYLES[status];

  return (
    <section
      aria-label="Analysis status"
      className="rounded-xl border border-slate-200 bg-white p-6 shadow-sm"
    >
      <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-start">
        <div>
          <div className="flex flex-wrap items-center gap-2.5">
            <span
              data-testid="analysis-status-badge"
              className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-0.5 text-xs font-semibold ${badgeStyle}`}
            >
              {(status === 'QUEUED' || status === 'BUILDING') && isPolling && (
                <span className="h-2 w-2 animate-pulse rounded-full bg-current" aria-hidden="true" />
              )}
              {status}
            </span>
            <span className="font-mono text-xs text-slate-500">ID: {analysisId}</span>
          </div>

          <h3 className="mt-2 text-base font-semibold text-slate-900">
            {statusData?.progress || STATUS_DESCRIPTIONS[status]}
          </h3>
          <p className="mt-0.5 text-sm text-slate-600">{STATUS_DESCRIPTIONS[status]}</p>
          {repositoryUrl && (
            <p className="mt-1 text-xs text-slate-500">
              Repository: <span className="font-medium text-slate-700">{repositoryUrl}</span>
            </p>
          )}
        </div>

        <div className="text-left text-xs text-slate-500 sm:text-right">
          {statusData && (
            <>
              <div>Created: {formatUtcTimestamp(statusData.createdAt)}</div>
              <div className="mt-0.5">Updated: {formatUtcTimestamp(statusData.updatedAt)}</div>
            </>
          )}
          {isPolling && (
            <div className="mt-1 text-slate-400">
              Polling every {(nextPollDelayMs / 1000).toFixed(1)}s
            </div>
          )}
        </div>
      </div>

      {status === 'FAILED' && statusData?.error && (
        <div
          role="alert"
          className="mt-4 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800"
        >
          <span className="font-semibold">{statusData.error.code}:</span> {statusData.error.message}
        </div>
      )}

      {fatalError && (
        <div
          role="alert"
          className="mt-4 flex flex-col justify-between gap-3 rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800 sm:flex-row sm:items-center"
        >
          <div>{fatalError}</div>
          <button
            type="button"
            onClick={onRetryNow}
            className="shrink-0 rounded-md border border-red-300 bg-white px-3 py-1.5 text-xs font-medium text-red-800 hover:bg-red-100"
          >
            Retry Lookup
          </button>
        </div>
      )}

      {transientError && !fatalError && (
        <div
          role="status"
          className="mt-4 flex flex-col justify-between gap-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 sm:flex-row sm:items-center"
        >
          <div>
            Temporary connection issue ({transientError}). Retrying automatically with backoff.
          </div>
          <button
            type="button"
            onClick={onRetryNow}
            className="shrink-0 rounded-md border border-amber-300 bg-white px-3 py-1.5 text-xs font-medium text-amber-900 hover:bg-amber-100"
          >
            Retry Now
          </button>
        </div>
      )}

      {timedOut && !fatalError && (
        <div
          role="alert"
          className="mt-4 flex flex-col justify-between gap-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 sm:flex-row sm:items-center"
        >
          <div>
            Polling reached the 10-minute client limit before reaching a terminal status. The job may still finish on the server.
          </div>
          <button
            type="button"
            onClick={onRetryNow}
            className="shrink-0 rounded-md border border-amber-300 bg-white px-3 py-1.5 text-xs font-medium text-amber-900 hover:bg-amber-100"
          >
            Resume Status Check
          </button>
        </div>
      )}
    </section>
  );
}
