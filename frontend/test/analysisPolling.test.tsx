import { act, render, renderHook, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AnalysisApiClient, ApiClientError } from '../src/api/client';
import { AnalysisProgress } from '../src/components/AnalysisProgress';
import { useAnalysisPolling } from '../src/hooks/useAnalysisPolling';
import { AnalysisPublicStatus } from '../src/types/analysis';

const TEST_ID = '550e8400-e29b-41d4-a716-446655440000';

describe('useAnalysisPolling & AnalysisProgress', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('polls with progressive backoff up to 10s, handles transient errors, and stops on COMPLETED', async () => {
    const responses: Array<AnalysisPublicStatus | Error> = [
      {
        analysisId: TEST_ID,
        status: 'QUEUED',
        progress: 'Queued...',
        createdAt: '2026-11-25T10:00:00Z',
        updatedAt: '2026-11-25T10:00:00Z',
        error: null,
      },
      new ApiClientError(503, 'SERVICE_UNAVAILABLE', 'Temporary blip'),
      {
        analysisId: TEST_ID,
        status: 'BUILDING',
        progress: 'Running analyzer...',
        createdAt: '2026-11-25T10:00:00Z',
        updatedAt: '2026-11-25T10:00:06Z',
        error: null,
      },
      {
        analysisId: TEST_ID,
        status: 'COMPLETED',
        progress: 'Analysis completed',
        createdAt: '2026-11-25T10:00:00Z',
        updatedAt: '2026-11-25T10:00:12Z',
        error: null,
      },
    ];

    let callCount = 0;
    const mockApi = {
      getAnalysisStatus: vi.fn(async () => {
        const next = responses[callCount] ?? responses[responses.length - 1]!;
        callCount += 1;
        if (next instanceof Error) {
          throw next;
        }
        return next;
      }),
    } as unknown as AnalysisApiClient;

    const { result } = renderHook(() =>
      useAnalysisPolling(TEST_ID, {
        api: mockApi,
        initialDelayMs: 2000,
        maxDelayMs: 10000,
        backoffFactor: 2,
        maxDurationMs: 600_000,
      }),
    );

    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current.statusData?.status).toBe('QUEUED');
    expect(result.current.nextPollDelayMs).toBe(4000);
    expect(result.current.isPolling).toBe(true);

    // Advance 4s -> hits transient 503 error -> backs off to 8s
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4000);
    });
    expect(result.current.transientError).toContain('Temporary blip');
    expect(result.current.nextPollDelayMs).toBe(8000);

    // Advance 8s -> hits BUILDING -> backoff capped strictly at 10s max
    await act(async () => {
      await vi.advanceTimersByTimeAsync(8000);
    });
    expect(result.current.statusData?.status).toBe('BUILDING');
    expect(result.current.transientError).toBeNull();
    expect(result.current.nextPollDelayMs).toBe(10000);

    // Advance 10s -> hits COMPLETED -> polling terminates
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10000);
    });
    expect(result.current.statusData?.status).toBe('COMPLETED');
    expect(result.current.isPolling).toBe(false);
    expect(callCount).toBe(4);
  });

  it('enforces 10-minute maximum polling timeout ceiling cleanly', async () => {
    const mockApi = {
      getAnalysisStatus: vi.fn(async () => ({
        analysisId: TEST_ID,
        status: 'BUILDING' as const,
        progress: 'Still analyzing...',
        createdAt: '2026-11-25T10:00:00Z',
        updatedAt: '2026-11-25T10:00:00Z',
        error: null,
      })),
    } as unknown as AnalysisApiClient;

    const { result } = renderHook(() =>
      useAnalysisPolling(TEST_ID, {
        api: mockApi,
        initialDelayMs: 2000,
        maxDelayMs: 10000,
        maxDurationMs: 600_000,
      }),
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(605_000);
    });

    expect(result.current.isPolling).toBe(false);
    expect(result.current.timedOut).toBe(true);
  });

  it('renders status without internal Jenkins IDs or fabricated percentage bars', () => {
    render(
      <AnalysisProgress
        analysisId={TEST_ID}
        repositoryUrl="https://github.com/octocat/Hello-World"
        statusData={{
          analysisId: TEST_ID,
          status: 'FAILED',
          progress: 'Analysis failed',
          createdAt: '2026-11-25T10:00:00Z',
          updatedAt: '2026-11-25T10:01:00Z',
          error: { code: 'ANALYSIS_FAILED', message: 'Build ended with FAILURE' },
        }}
        isPolling={false}
        transientError={null}
        fatalError={null}
        timedOut={false}
        nextPollDelayMs={2000}
        onRetryNow={() => undefined}
      />,
    );

    expect(screen.getByTestId('analysis-status-badge')).toHaveTextContent('FAILED');
    expect(screen.getByRole('alert')).toHaveTextContent('ANALYSIS_FAILED: Build ended with FAILURE');
    expect(document.body.textContent).not.toMatch(/queueId|buildNumber|%/);
  });
});
