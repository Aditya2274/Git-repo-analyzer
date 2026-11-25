import React, { useCallback, useEffect, useState } from 'react';
import { AnalysisApiClient, ApiClientError, apiClient } from './api/client';
import { ActivityCharts } from './components/ActivityCharts';
import { AnalysisProgress } from './components/AnalysisProgress';
import { MarkdownReport } from './components/MarkdownReport';
import { MetricCards } from './components/MetricCards';
import { RepoInputForm } from './components/RepoInputForm';
import { useAnalysisPolling } from './hooks/useAnalysisPolling';
import {
  AnalysisResultsResponse,
  isTerminalStatus,
  isValidUuidV4,
  SessionHistoryItem,
} from './types/analysis';

export interface AppProps {
  api?: AnalysisApiClient;
  initialPollDelayMs?: number;
}

function readInitialAnalysisIdFromUrl(): string | null {
  try {
    const params = new URLSearchParams(window.location.search);
    const candidate = params.get('analysisId');
    return candidate && isValidUuidV4(candidate) ? candidate : null;
  } catch {
    return null;
  }
}

export function App({ api = apiClient, initialPollDelayMs }: AppProps): React.ReactElement {
  const [healthState, setHealthState] = useState<'checking' | 'up' | 'down'>('checking');
  const [activeAnalysisId, setActiveAnalysisId] = useState<string | null>(() =>
    readInitialAnalysisIdFromUrl(),
  );
  const [activeRepoUrl, setActiveRepoUrl] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [sessionHistory, setSessionHistory] = useState<SessionHistoryItem[]>([]);

  const [results, setResults] = useState<AnalysisResultsResponse | null>(null);
  const [resultsLoading, setResultsLoading] = useState(false);
  const [resultsError, setResultsError] = useState<string | null>(null);
  const [resultsNonce, setResultsNonce] = useState(0);

  const polling = useAnalysisPolling(activeAnalysisId, {
    api,
    ...(initialPollDelayMs !== undefined ? { initialDelayMs: initialPollDelayMs } : {}),
  });

  // Check backend readiness on mount cleanly
  useEffect(() => {
    const controller = new AbortController();
    api
      .getHealth(controller.signal)
      .then((res) => {
        setHealthState(res.status === 'UP' ? 'up' : 'down');
      })
      .catch((err) => {
        if (err instanceof Error && err.name === 'AbortError') return;
        setHealthState('down');
      });
    return () => controller.abort();
  }, [api]);

  // Sync query parameter cleanly for bookmarkable lookup
  useEffect(() => {
    try {
      const url = new URL(window.location.href);
      if (activeAnalysisId) {
        url.searchParams.set('analysisId', activeAnalysisId);
      } else {
        url.searchParams.delete('analysisId');
      }
      window.history.replaceState(null, '', url.toString());
    } catch {
      // Ignore history update failures in restricted environments
    }
  }, [activeAnalysisId]);

  // Sync terminal status into session-local pill list
  useEffect(() => {
    if (!polling.statusData) {
      return;
    }
    const { analysisId, status } = polling.statusData;
    setSessionHistory((prev) =>
      prev.map((item) => (item.analysisId === analysisId ? { ...item, lastStatus: status } : item)),
    );
  }, [polling.statusData]);

  // Load GET /api/analyses/:id/results once status reaches COMPLETED
  useEffect(() => {
    if (!activeAnalysisId || polling.statusData?.status !== 'COMPLETED') {
      setResults(null);
      setResultsLoading(false);
      setResultsError(null);
      return;
    }

    const controller = new AbortController();
    setResultsLoading(true);
    setResultsError(null);

    api
      .getAnalysisResults(activeAnalysisId, controller.signal)
      .then((payload) => {
        setResults(payload);
        setActiveRepoUrl(payload.repositoryUrl);
        setResultsLoading(false);
      })
      .catch((err) => {
        if (err instanceof Error && err.name === 'AbortError') return;
        const msg =
          err instanceof ApiClientError || err instanceof Error
            ? err.message
            : 'Unable to fetch completed analysis results.';
        setResultsError(msg);
        setResultsLoading(false);
      });

    return () => controller.abort();
  }, [activeAnalysisId, api, polling.statusData?.status, resultsNonce]);

  const handleSubmitRepo = useCallback(
    async (repositoryUrl: string) => {
      setIsSubmitting(true);
      setSubmitError(null);
      try {
        const accepted = await api.submitAnalysis(repositoryUrl);
        setActiveAnalysisId(accepted.analysisId);
        setActiveRepoUrl(repositoryUrl);
        setResults(null);
        setResultsError(null);
        setSessionHistory((prev) => {
          const nextItem: SessionHistoryItem = {
            analysisId: accepted.analysisId,
            repositoryUrl,
            createdAt: accepted.createdAt,
            lastStatus: 'QUEUED',
          };
          return [nextItem, ...prev.filter((i) => i.analysisId !== accepted.analysisId)].slice(0, 6);
        });
      } catch (err) {
        const msg =
          err instanceof ApiClientError || err instanceof Error
            ? err.message
            : 'Failed to submit repository analysis request.';
        setSubmitError(msg);
      } finally {
        setIsSubmitting(false);
      }
    },
    [api],
  );

  const handleLookupAnalysisId = useCallback((analysisId: string) => {
    setSubmitError(null);
    setResults(null);
    setResultsError(null);
    setActiveRepoUrl(null);
    setActiveAnalysisId(analysisId.trim());
  }, []);

  const hasInFlightAnalysis =
    activeAnalysisId !== null &&
    polling.fatalError === null &&
    !polling.timedOut &&
    (!polling.statusData || !isTerminalStatus(polling.statusData.status));

  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-6xl flex-col justify-between gap-3 px-4 py-4 sm:flex-row sm:items-center sm:px-6">
          <div>
            <h1 className="text-xl font-bold tracking-tight text-slate-900">
              AI-Powered Git Repository Analyzer
            </h1>
            <p className="text-xs text-slate-500">
              Automated Git Health Metrics, Activity Visualizations &amp; Architectural Report Dashboard
            </p>
          </div>
          <div className="flex items-center gap-2">
            <span
              data-testid="backend-health-pill"
              className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium ${
                healthState === 'up'
                  ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
                  : healthState === 'down'
                    ? 'border-red-200 bg-red-50 text-red-800'
                    : 'border-slate-200 bg-slate-100 text-slate-600'
              }`}
            >
              <span
                className={`h-2 w-2 rounded-full ${
                  healthState === 'up'
                    ? 'bg-emerald-500'
                    : healthState === 'down'
                      ? 'bg-red-500'
                      : 'bg-slate-400'
                }`}
              />
              {healthState === 'up'
                ? 'Backend API: UP'
                : healthState === 'down'
                  ? 'Backend API: Unavailable'
                  : 'Checking API...'}
            </span>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl space-y-6 px-4 py-8 sm:px-6">
        <RepoInputForm
          onSubmitRepo={handleSubmitRepo}
          onLookupAnalysisId={handleLookupAnalysisId}
          isSubmitting={isSubmitting}
          hasInFlightAnalysis={hasInFlightAnalysis}
          submitError={submitError}
          sessionHistory={sessionHistory}
          activeAnalysisId={activeAnalysisId}
        />

        {!activeAnalysisId ? (
          <section className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center">
            <h3 className="text-base font-semibold text-slate-800">No Active Analysis Selected</h3>
            <p className="mx-auto mt-1 max-w-lg text-sm text-slate-500">
              Submit a public GitHub repository HTTPS URL above or load an existing <code className="font-mono text-xs">analysisId</code> to monitor execution progress and view metrics, PNG charts, and reports.
            </p>
          </section>
        ) : (
          <div className="space-y-6">
            <AnalysisProgress
              analysisId={activeAnalysisId}
              repositoryUrl={activeRepoUrl}
              statusData={polling.statusData}
              isPolling={polling.isPolling}
              transientError={polling.transientError}
              fatalError={polling.fatalError}
              timedOut={polling.timedOut}
              nextPollDelayMs={polling.nextPollDelayMs}
              onRetryNow={polling.retryNow}
            />

            {polling.statusData?.status === 'COMPLETED' && (
              <>
                {resultsLoading ? (
                  <div
                    role="status"
                    className="rounded-xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600 shadow-sm"
                  >
                    Loading completed analysis metrics, charts, and report...
                  </div>
                ) : resultsError ? (
                  <div
                    role="alert"
                    className="flex flex-col justify-between gap-3 rounded-xl border border-red-200 bg-red-50 p-5 text-sm text-red-800 sm:flex-row sm:items-center"
                  >
                    <div>Failed to load analysis results: {resultsError}</div>
                    <button
                      type="button"
                      onClick={() => setResultsNonce((n) => n + 1)}
                      className="rounded-md border border-red-300 bg-white px-3 py-1.5 text-xs font-medium text-red-800 hover:bg-red-100"
                    >
                      Retry Results
                    </button>
                  </div>
                ) : results ? (
                  <>
                    <MetricCards results={results} />
                    <ActivityCharts results={results} api={api} />
                    <MarkdownReport summaryMarkdown={results.summaryMarkdown} />
                  </>
                ) : null}
              </>
            )}
          </div>
        )}
      </main>
    </div>
  );
}

export default App;
