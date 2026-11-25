import { useCallback, useEffect, useRef, useState } from 'react';
import { AnalysisApiClient, ApiClientError, apiClient } from '../api/client';
import { AnalysisPublicStatus, isTerminalStatus } from '../types/analysis';

export interface UseAnalysisPollingOptions {
  api?: AnalysisApiClient;
  initialDelayMs?: number;
  maxDelayMs?: number;
  backoffFactor?: number;
  maxDurationMs?: number;
}

export interface UseAnalysisPollingState {
  statusData: AnalysisPublicStatus | null;
  isPolling: boolean;
  transientError: string | null;
  fatalError: string | null;
  timedOut: boolean;
  nextPollDelayMs: number;
  retryNow: () => void;
}

/**
 * Polls GET /api/analyses/:id cleanly from 2s up to 10s backoff ceiling and stops
 * on COMPLETED/FAILED/CANCELLED or after the 10-minute safety ceiling.
 */
export function useAnalysisPolling(
  analysisId: string | null,
  options: UseAnalysisPollingOptions = {},
): UseAnalysisPollingState {
  const api = options.api ?? apiClient;
  const initialDelayMs = options.initialDelayMs ?? 2000;
  const maxDelayMs = options.maxDelayMs ?? 10_000;
  const backoffFactor = options.backoffFactor ?? 1.5;
  const maxDurationMs = options.maxDurationMs ?? 600_000;

  const [statusData, setStatusData] = useState<AnalysisPublicStatus | null>(null);
  const [isPolling, setIsPolling] = useState(false);
  const [transientError, setTransientError] = useState<string | null>(null);
  const [fatalError, setFatalError] = useState<string | null>(null);
  const [timedOut, setTimedOut] = useState(false);
  const [nextPollDelayMs, setNextPollDelayMs] = useState(initialDelayMs);
  const [restartNonce, setRestartNonce] = useState(0);

  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const clearScheduled = useCallback(() => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    if (abortRef.current !== null) {
      abortRef.current.abort();
      abortRef.current = null;
    }
  }, []);

  const retryNow = useCallback(() => {
    if (!analysisId) {
      return;
    }
    setTimedOut(false);
    setFatalError(null);
    setTransientError(null);
    setRestartNonce((n) => n + 1);
  }, [analysisId]);

  useEffect(() => {
    clearScheduled();

    if (!analysisId) {
      setStatusData(null);
      setIsPolling(false);
      setTransientError(null);
      setFatalError(null);
      setTimedOut(false);
      setNextPollDelayMs(initialDelayMs);
      return;
    }

    let cancelled = false;
    const startedAtMs = Date.now();
    let delayMs = initialDelayMs;

    setStatusData(null);
    setIsPolling(true);
    setTransientError(null);
    setFatalError(null);
    setTimedOut(false);
    setNextPollDelayMs(initialDelayMs);

    const scheduleNext = (delay: number) => {
      if (cancelled) {
        return;
      }
      const elapsed = Date.now() - startedAtMs;
      if (elapsed >= maxDurationMs) {
        setIsPolling(false);
        setTimedOut(true);
        return;
      }

      const boundedDelay = Math.min(delay, maxDurationMs - elapsed);
      setNextPollDelayMs(boundedDelay);
      timerRef.current = setTimeout(() => {
        timerRef.current = null;
        void pollOnce();
      }, boundedDelay);
    };

    const pollOnce = async () => {
      if (cancelled) {
        return;
      }
      if (Date.now() - startedAtMs >= maxDurationMs) {
        setIsPolling(false);
        setTimedOut(true);
        return;
      }

      const controller = new AbortController();
      abortRef.current = controller;

      try {
        const nextStatus = await api.getAnalysisStatus(analysisId, controller.signal);
        if (cancelled) {
          return;
        }
        if (!nextStatus || typeof nextStatus.status !== 'string') {
          throw new Error('Malformed analysis status response received from backend.');
        }
        setStatusData(nextStatus);
        setTransientError(null);
        setFatalError(null);

        if (isTerminalStatus(nextStatus.status)) {
          setIsPolling(false);
          return;
        }

        delayMs = Math.min(maxDelayMs, Math.round(delayMs * backoffFactor));
        scheduleNext(delayMs);
      } catch (err) {
        if (cancelled) {
          return;
        }
        if (err instanceof Error && err.name === 'AbortError') {
          return;
        }

        if (err instanceof ApiClientError && (err.statusCode === 400 || err.statusCode === 404)) {
          setIsPolling(false);
          setFatalError(err.message);
          return;
        }

        const msg =
          err instanceof Error
            ? err.message
            : 'Temporary connection issue while checking analysis status.';
        setTransientError(msg);
        delayMs = Math.min(maxDelayMs, Math.round(delayMs * backoffFactor));
        scheduleNext(delayMs);
      }
    };

    void pollOnce();

    return () => {
      cancelled = true;
      clearScheduled();
    };
  }, [analysisId, api, backoffFactor, clearScheduled, initialDelayMs, maxDelayMs, maxDurationMs, restartNonce]);

  return {
    statusData,
    isPolling,
    transientError,
    fatalError,
    timedOut,
    nextPollDelayMs,
    retryNow,
  };
}
