import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { AnalysisApiClient } from '../src/api/client';
import { ActivityCharts } from '../src/components/ActivityCharts';
import { MarkdownReport } from '../src/components/MarkdownReport';
import { MetricCards } from '../src/components/MetricCards';
import { AnalysisResultsResponse } from '../src/types/analysis';

const TEST_ID = '550e8400-e29b-41d4-a716-446655440000';

function makeCompletedResults(zeroCommits = false): AnalysisResultsResponse {
  if (zeroCommits) {
    return {
      analysisId: TEST_ID,
      repositoryUrl: 'https://github.com/octocat/Empty-Repo',
      status: 'COMPLETED',
      createdAt: '2026-11-25T10:00:00Z',
      updatedAt: '2026-11-25T10:01:00Z',
      metrics: {
        generatedAt: '2026-11-25T10:00:00Z',
        repository: { mainBranch: 'main', commitHistoryAvailable: false },
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
        branchDrift: { mainBranch: 'main', branchesAnalyzed: 0, staleBranches: [] },
      },
      summaryMarkdown: '# Git Repository Analysis Report\n\n**No commits found — charts will be skipped.**',
      charts: { commitsPerAuthor: null, dailyActivity: null },
    };
  }

  return {
    analysisId: TEST_ID,
    repositoryUrl: 'https://github.com/octocat/Hello-World',
    status: 'COMPLETED',
    createdAt: '2026-11-25T10:00:00Z',
    updatedAt: '2026-11-25T10:01:00Z',
    metrics: {
      generatedAt: '2026-11-25T10:00:00Z',
      repository: { mainBranch: 'main', trackedFiles: 28, commitHistoryAvailable: true },
      busFactor: {
        formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
        threshold: 4.25,
        filesAnalyzed: 28,
        criticalFileCount: 1,
        topRisk: {
          file: 'src/core/engine.ts',
          topAuthor: 'Alice Developer',
          doa: 4.791,
          firstAuthor: 'Alice Developer',
          dl: 9,
          ac: 2,
          share: 0.818,
          riskLevel: 'critical',
          commits: 11,
        },
        criticalFiles: [],
        highRiskFiles: [
          {
            file: 'src/core/engine.ts',
            topAuthor: 'Alice Developer',
            doa: 4.791,
            firstAuthor: 'Alice Developer',
            dl: 9,
            ac: 2,
            share: 0.818,
            riskLevel: 'critical',
            commits: 11,
          },
        ],
        authorSummary: [{ author: 'Alice Developer', fileCount: 18, averageDoa: 4.12, maxDoa: 4.791 }],
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
    },
    summaryMarkdown: '# AI Insights\n\n| File | Note |\n|---|---|\n| engine.ts | High churn |\n',
    charts: {
      commitsPerAuthor: `/api/analyses/${TEST_ID}/charts/commits_per_author.png`,
      dailyActivity: `/api/analyses/${TEST_ID}/charts/daily_commit_activity.png`,
    },
  };
}

describe('MetricCards, ActivityCharts, and MarkdownReport', () => {
  it('renders accurate metrics.json labels without fabricating all-time commit stats', () => {
    const results = makeCompletedResults(false);
    render(<MetricCards results={results} />);

    expect(screen.getByText('octocat/Hello-World')).toBeInTheDocument();
    expect(screen.getByText(/30-Day Hotspot Window Churn/i)).toBeInTheDocument();
    expect(screen.getByText('+680')).toBeInTheDocument();
    expect(screen.getByText('-215')).toBeInTheDocument();
    expect(screen.getByText('feature/legacy-export')).toBeInTheDocument();
    expect(screen.getByText(/Last 30 days only/i)).toBeInTheDocument();
    expect(screen.queryByText(/All-time insertions/i)).toBeNull();
  });

  it('fetches PNG charts cleanly via API client, handles errors without broken img tags, and handles zero-commit omission', async () => {
    const okApi = {
      fetchChartBlobUrl: vi.fn(async (p: string) => `blob:http://localhost/${encodeURIComponent(p)}`),
    } as unknown as AnalysisApiClient;

    const { rerender } = render(<ActivityCharts results={makeCompletedResults(false)} api={okApi} />);
    await waitFor(() => {
      const imgs = screen.getAllByRole('img');
      expect(imgs).toHaveLength(2);
    });

    // Zero-commit omits PNGs cleanly with explanatory text and zero broken <img>
    rerender(<ActivityCharts results={makeCompletedResults(true)} api={okApi} />);
    expect(screen.queryAllByRole('img')).toHaveLength(0);
    expect(
      screen.getAllByText(/analyzer skips commit charts on repositories with zero commits/i),
    ).toHaveLength(2);

    // Chart HTTP/network error displays error panel and zero broken <img>
    const failingApi = {
      fetchChartBlobUrl: vi.fn(async () => {
        throw new Error('Chart missing from cache');
      }),
    } as unknown as AnalysisApiClient;

    rerender(<ActivityCharts results={makeCompletedResults(false)} api={failingApi} />);
    await waitFor(() => {
      expect(screen.getAllByRole('alert')).toHaveLength(2);
    });
    expect(screen.queryAllByRole('img')).toHaveLength(0);
  });

  it('safely renders GFM Markdown and neutralizes unsafe HTML/XSS payloads', () => {
    const unsafeMd = [
      '# Safe Report Title',
      '',
      '<script>window.__xss=true;</script>',
      '',
      '<img src="x" onerror="alert(1)" />',
      '',
      '[Safe Link](https://github.com/octocat/Hello-World)',
      '',
      '[Blocked Link](javascript:alert(1))',
      '',
      '| Metric | Value |',
      '| --- | --- |',
      '| Status | Valid |',
    ].join('\n');

    const { container, rerender } = render(<MarkdownReport summaryMarkdown={unsafeMd} />);
    expect(screen.getByText('Safe Report Title')).toBeInTheDocument();
    expect(screen.getByRole('table')).toBeInTheDocument();
    expect(container.querySelector('script')).toBeNull();
    expect(container.querySelector('img[onerror]')).toBeNull();
    expect(screen.getByRole('link', { name: 'Safe Link' })).toHaveAttribute(
      'href',
      'https://github.com/octocat/Hello-World',
    );
    const blocked = container.querySelector('a[href^="javascript:"]');
    expect(blocked).toBeNull();

    // Empty report renders cleanly
    rerender(<MarkdownReport summaryMarkdown="   " />);
    expect(screen.getByText(/Report summary artifact is empty or unavailable/i)).toBeInTheDocument();
  });
});
