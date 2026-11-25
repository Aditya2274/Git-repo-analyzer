import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AnalysisApiClient, ApiClientError } from '../src/api/client';
import { App } from '../src/App';
import { AnalysisResultsResponse } from '../src/types/analysis';

const MOCK_ID = '550e8400-e29b-41d4-a716-446655440000';

const MOCK_RESULTS: AnalysisResultsResponse = {
  analysisId: MOCK_ID,
  repositoryUrl: 'https://github.com/octocat/Hello-World',
  status: 'COMPLETED',
  createdAt: '2026-11-25T10:00:00Z',
  updatedAt: '2026-11-25T10:00:10Z',
  metrics: {
    generatedAt: '2026-11-25T10:00:00Z',
    repository: { mainBranch: 'main', trackedFiles: 12, commitHistoryAvailable: true },
    busFactor: {
      formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
      threshold: 4.25,
      filesAnalyzed: 12,
      criticalFileCount: 1,
      topRisk: null,
      criticalFiles: [],
      highRiskFiles: [],
      authorSummary: [{ author: 'Octocat', fileCount: 12, averageDoa: 4.5, maxDoa: 4.5 }],
    },
    hotspots: {
      windowDays: 30,
      decayLambda: 0.05,
      totalLoc: 500,
      totalInsertions: 90,
      totalDeletions: 10,
      topHotspots: [
        {
          file: 'README.md',
          additions: 90,
          deletions: 10,
          loc: 100,
          commitCount: 3,
          daysSinceChange: 1,
          churn: 100,
          hotspotScore: 285,
        },
      ],
    },
    branchDrift: { mainBranch: 'main', branchesAnalyzed: 0, staleBranches: [] },
  },
  summaryMarkdown: '# AI Repository Overview\n\nAll checks clean.',
  charts: {
    commitsPerAuthor: `/api/analyses/${MOCK_ID}/charts/commits_per_author.png`,
    dailyActivity: `/api/analyses/${MOCK_ID}/charts/daily_commit_activity.png`,
  },
};

describe('App end-to-end mock workflow', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/');
  });

  it('completes submit -> QUEUED -> BUILDING -> COMPLETED -> results + charts + markdown flow', async () => {
    const user = userEvent.setup();
    let pollIdx = 0;

    const mockApi: AnalysisApiClient = {
      getHealth: vi.fn(async () => ({ status: 'UP', timestamp: '2026-11-25T10:00:00Z' })),
      submitAnalysis: vi.fn(async () => ({
        analysisId: MOCK_ID,
        status: 'QUEUED' as const,
        createdAt: '2026-11-25T10:00:00Z',
      })),
      getAnalysisStatus: vi.fn(async () => {
        pollIdx += 1;
        if (pollIdx === 1) {
          return {
            analysisId: MOCK_ID,
            status: 'QUEUED' as const,
            progress: 'Queued...',
            createdAt: '2026-11-25T10:00:00Z',
            updatedAt: '2026-11-25T10:00:00Z',
            error: null,
          };
        }
        if (pollIdx === 2) {
          return {
            analysisId: MOCK_ID,
            status: 'BUILDING' as const,
            progress: 'Running analyzer...',
            createdAt: '2026-11-25T10:00:00Z',
            updatedAt: '2026-11-25T10:00:02Z',
            error: null,
          };
        }
        return {
          analysisId: MOCK_ID,
          status: 'COMPLETED' as const,
          progress: 'Analysis completed',
          createdAt: '2026-11-25T10:00:00Z',
          updatedAt: '2026-11-25T10:00:05Z',
          error: null,
        };
      }),
      getAnalysisResults: vi.fn(async () => MOCK_RESULTS),
      resolveChartUrl: (p) => p,
      fetchChartBlobUrl: vi.fn(async (p) => `blob:http://localhost/${encodeURIComponent(p)}`),
    };

    render(<App api={mockApi} initialPollDelayMs={20} />);

    await waitFor(() => {
      expect(screen.getByTestId('backend-health-pill')).toHaveTextContent('Backend API: UP');
    });

    await user.type(
      screen.getByLabelText(/GitHub Repository HTTPS URL/i),
      'https://github.com/octocat/Hello-World',
    );
    await user.click(screen.getByRole('button', { name: /Start Analysis/i }));

    await waitFor(() => {
      expect(screen.getByTestId('analysis-status-badge')).toHaveTextContent('COMPLETED');
    });

    await waitFor(() => {
      expect(screen.getByRole('heading', { name: 'octocat/Hello-World' })).toBeInTheDocument();
      expect(screen.getByText('AI Repository Overview')).toBeInTheDocument();
      expect(screen.getAllByRole('img')).toHaveLength(2);
    });
  });

  it('displays backend error cleanly on failed submission', async () => {
    const user = userEvent.setup();
    const failingApi: AnalysisApiClient = {
      getHealth: vi.fn(async () => ({ status: 'UP', timestamp: '2026-11-25T10:00:00Z' })),
      submitAnalysis: vi.fn(async () => {
        throw new ApiClientError(503, 'SERVICE_UNAVAILABLE', 'CI controller offline');
      }),
      getAnalysisStatus: vi.fn(async () => {
        throw new Error('Unexpected status poll before submission accepted');
      }),
      getAnalysisResults: vi.fn(async () => MOCK_RESULTS),
      resolveChartUrl: (p) => p,
      fetchChartBlobUrl: vi.fn(async (p) => `blob:http://localhost/${encodeURIComponent(p)}`),
    };

    render(<App api={failingApi} />);
    await user.type(
      screen.getByLabelText(/GitHub Repository HTTPS URL/i),
      'https://github.com/octocat/Hello-World',
    );
    await act(async () => {
      await user.click(screen.getByRole('button', { name: /Start Analysis/i }));
    });

    expect(screen.getByRole('alert')).toHaveTextContent('CI controller offline');
  });
});
