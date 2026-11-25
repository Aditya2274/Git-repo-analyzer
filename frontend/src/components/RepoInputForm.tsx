import React, { FormEvent, useState } from 'react';
import { isValidUuidV4, SessionHistoryItem, formatRepositorySlug } from '../types/analysis';

export interface RepoInputFormProps {
  onSubmitRepo: (repositoryUrl: string) => Promise<void>;
  onLookupAnalysisId: (analysisId: string) => void;
  isSubmitting: boolean;
  hasInFlightAnalysis: boolean;
  submitError: string | null;
  sessionHistory: SessionHistoryItem[];
  activeAnalysisId: string | null;
}

/**
 * Lightweight pre-submit sanity check only; backend Zod + DNS/IP SSRF controls
 * remain authoritative for security enforcement.
 */
export function validateBasicGitHubUrl(rawInput: string): string | null {
  const trimmed = rawInput.trim();
  if (!trimmed) {
    return 'Please enter a public GitHub repository URL.';
  }
  if (/[\s\x00-\x1f]/.test(trimmed)) {
    return 'Repository URL must not contain spaces or control characters.';
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return 'Enter a valid URL such as https://github.com/owner/repository.';
  }

  if (parsed.protocol !== 'https:') {
    return 'Only https:// GitHub repository URLs are permitted.';
  }
  if (parsed.username || parsed.password) {
    return 'Embedded credentials in URLs are not allowed.';
  }
  if (parsed.port) {
    return 'Unexpected port specified; omit custom ports for github.com.';
  }
  if (parsed.hostname.toLowerCase() !== 'github.com') {
    return 'Only repositories hosted directly on github.com are allowed.';
  }
  if (parsed.search || parsed.hash || trimmed.includes('?') || trimmed.includes('#')) {
    return 'Query strings and URL fragments are not permitted.';
  }

  const segments = parsed.pathname.split('/').filter(Boolean);
  if (segments.length !== 2) {
    return 'Specify the full repository path: https://github.com/<owner>/<repository>.';
  }

  return null;
}

export function RepoInputForm({
  onSubmitRepo,
  onLookupAnalysisId,
  isSubmitting,
  hasInFlightAnalysis,
  submitError,
  sessionHistory,
  activeAnalysisId,
}: RepoInputFormProps): React.ReactElement {
  const [urlInput, setUrlInput] = useState('');
  const [clientError, setClientError] = useState<string | null>(null);
  const [lookupInput, setLookupInput] = useState('');
  const [lookupError, setLookupError] = useState<string | null>(null);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (isSubmitting || hasInFlightAnalysis) {
      return;
    }

    const validationIssue = validateBasicGitHubUrl(urlInput);
    if (validationIssue) {
      setClientError(validationIssue);
      return;
    }

    setClientError(null);
    await onSubmitRepo(urlInput.trim());
  };

  const handleLookup = (e: FormEvent) => {
    e.preventDefault();
    const candidate = lookupInput.trim();
    if (!isValidUuidV4(candidate)) {
      setLookupError('Enter a valid UUID v4 analysisId (e.g., 550e8400-e29b-41d4-a716-446655440000).');
      return;
    }
    setLookupError(null);
    onLookupAnalysisId(candidate);
  };

  const combinedError = clientError ?? submitError;

  return (
    <section
      aria-label="Submit repository for analysis"
      className="rounded-xl border border-slate-200 bg-white p-6 shadow-sm"
    >
      <div className="mb-4">
        <h2 className="text-lg font-semibold text-slate-900">Analyze a Public GitHub Repository</h2>
        <p className="mt-1 text-sm text-slate-600">
          Submit a public <code className="rounded bg-slate-100 px-1.5 py-0.5 text-xs">https://github.com/owner/repo</code> URL.
          The Express backend validates inputs, enforces SSRF protections, and dispatches analysis jobs cleanly.
        </p>
      </div>

      <form onSubmit={(e) => void handleSubmit(e)} noValidate className="space-y-3">
        <div className="flex flex-col gap-3 sm:flex-row">
          <div className="flex-1">
            <label htmlFor="repository-url-input" className="sr-only">
              GitHub Repository HTTPS URL
            </label>
            <input
              id="repository-url-input"
              name="repositoryUrl"
              type="url"
              value={urlInput}
              onChange={(e) => {
                setUrlInput(e.target.value);
                if (clientError) setClientError(null);
              }}
              placeholder="https://github.com/octocat/Hello-World"
              disabled={isSubmitting}
              className="w-full rounded-lg border border-slate-300 bg-white px-3.5 py-2.5 text-sm text-slate-900 placeholder:text-slate-400 focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-600/20 disabled:bg-slate-100"
            />
          </div>
          <button
            type="submit"
            disabled={isSubmitting || hasInFlightAnalysis}
            className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white shadow-sm transition hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-600 focus:ring-offset-2 disabled:cursor-not-allowed disabled:bg-slate-400"
          >
            {isSubmitting
              ? 'Submitting...'
              : hasInFlightAnalysis
                ? 'Analysis In Progress...'
                : 'Start Analysis'}
          </button>
        </div>

        {combinedError && (
          <div
            role="alert"
            className="rounded-lg border border-red-200 bg-red-50 px-3.5 py-2.5 text-sm text-red-800"
          >
            {combinedError}
          </div>
        )}
      </form>

      <div className="mt-5 border-t border-slate-100 pt-4">
        <form onSubmit={handleLookup} noValidate className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <label htmlFor="analysis-id-lookup" className="text-xs font-medium text-slate-600 sm:whitespace-nowrap">
            Open by Analysis ID:
          </label>
          <input
            id="analysis-id-lookup"
            type="text"
            value={lookupInput}
            onChange={(e) => {
              setLookupInput(e.target.value);
              if (lookupError) setLookupError(null);
            }}
            placeholder="Paste existing UUID v4 analysisId"
            className="flex-1 rounded-md border border-slate-300 px-3 py-1.5 font-mono text-xs text-slate-800 placeholder:text-slate-400 focus:border-blue-600 focus:outline-none focus:ring-1 focus:ring-blue-600"
          />
          <button
            type="submit"
            className="rounded-md border border-slate-300 bg-slate-50 px-3.5 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-100"
          >
            Load Analysis
          </button>
        </form>
        {lookupError && (
          <p role="alert" className="mt-1.5 text-xs text-red-700">
            {lookupError}
          </p>
        )}

        {sessionHistory.length > 0 && (
          <div className="mt-3">
            <p className="text-xs font-medium text-slate-500">
              Current Browser Session Submissions (client-local navigation):
            </p>
            <div className="mt-1.5 flex flex-wrap gap-2">
              {sessionHistory.map((item) => {
                const isSelected = item.analysisId === activeAnalysisId;
                return (
                  <button
                    key={item.analysisId}
                    type="button"
                    onClick={() => onLookupAnalysisId(item.analysisId)}
                    className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs transition ${
                      isSelected
                        ? 'border-blue-600 bg-blue-50 font-medium text-blue-800'
                        : 'border-slate-200 bg-slate-50 text-slate-700 hover:bg-slate-100'
                    }`}
                  >
                    <span>{formatRepositorySlug(item.repositoryUrl)}</span>
                    <span className="font-mono text-[10px] text-slate-500">
                      {item.analysisId.slice(0, 8)}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
