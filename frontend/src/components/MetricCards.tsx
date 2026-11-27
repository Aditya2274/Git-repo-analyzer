import React from 'react';
import {
  AnalysisResultsResponse,
  formatRepositorySlug,
  formatUtcTimestamp,
} from '../types/analysis';

export interface MetricCardsProps {
  results: AnalysisResultsResponse;
}

const RISK_BADGE_CLASS: Record<string, string> = {
  critical: 'border-red-200 bg-red-50 text-red-800',
  high: 'border-amber-200 bg-amber-50 text-amber-800',
  moderate: 'border-slate-200 bg-slate-100 text-slate-700',
};

function riskClass(level: string): string {
  return RISK_BADGE_CLASS[level.toLowerCase()] ?? 'border-slate-200 bg-slate-100 text-slate-700';
}

export function MetricCards({ results }: MetricCardsProps): React.ReactElement {
  const { metrics } = results;
  const { repository, busFactor, hotspots, branchDrift } = metrics;

  return (
    <div className="space-y-6">
      {/* Repository Overview */}
      <section
        aria-label="Repository overview"
        className="rounded-xl border border-slate-200 bg-white p-6 shadow-sm"
      >
        <div className="flex flex-col justify-between gap-4 border-b border-slate-100 pb-4 sm:flex-row sm:items-center">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-blue-600">
              Analyzed Repository
            </p>
            <h2 className="mt-0.5 text-xl font-bold text-slate-900">
              {formatRepositorySlug(results.repositoryUrl)}
            </h2>
            <p className="mt-1 break-all text-xs text-slate-500">{results.repositoryUrl}</p>
          </div>
          <div className="flex flex-wrap gap-2">
            <span className="inline-flex items-center rounded-md border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-medium text-slate-700">
              Branch: {repository.mainBranch}
            </span>
            <span
              className={`inline-flex items-center rounded-md border px-2.5 py-1 text-xs font-medium ${
                repository.commitHistoryAvailable
                  ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
                  : 'border-amber-200 bg-amber-50 text-amber-800'
              }`}
            >
              {repository.commitHistoryAvailable ? 'Commit History Available' : 'Zero-Commit Repository'}
            </span>
          </div>
        </div>

        <dl className="mt-4 grid grid-cols-1 gap-4 text-xs sm:grid-cols-3">
          <div>
            <dt className="text-slate-500">Metrics Timestamp</dt>
            <dd className="mt-0.5 font-medium text-slate-900">
              {formatUtcTimestamp(metrics.generatedAt)}
            </dd>
          </div>
          <div>
            <dt className="text-slate-500">Tracked Files Analyzed</dt>
            <dd className="mt-0.5 font-medium text-slate-900">
              {repository.trackedFiles !== undefined ? repository.trackedFiles : '0 (empty repository)'}
            </dd>
          </div>
          <div>
            <dt className="text-slate-500">Bus Factor Model</dt>
            <dd className="mt-0.5 font-mono text-[11px] text-slate-700">
              {busFactor.formula} (critical &ge; {busFactor.threshold})
            </dd>
          </div>
        </dl>
      </section>

      {/* Structured Metric Cards (metrics.json only) */}
      <section aria-label="Structured repository metrics">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-medium text-slate-500">Critical Bus-Factor Files</p>
            <p className="mt-2 text-2xl font-bold text-slate-900">
              {busFactor.criticalFileCount}
              <span className="ml-1.5 text-sm font-normal text-slate-500">
                / {busFactor.filesAnalyzed} analyzed
              </span>
            </p>
            <p className="mt-1 text-xs text-slate-500">
              High-risk files listed: {busFactor.highRiskFiles.length}
            </p>
          </div>

          <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-medium text-slate-500">
              {hotspots.windowDays}-Day Hotspot Window Churn
            </p>
            <p className="mt-2 text-2xl font-bold text-slate-900">
              <span className="text-emerald-700">+{hotspots.totalInsertions}</span>
              <span className="mx-1.5 text-slate-400">/</span>
              <span className="text-red-700">-{hotspots.totalDeletions}</span>
            </p>
            <p className="mt-1 text-xs text-slate-500">
              Last {hotspots.windowDays} days only &middot; {hotspots.totalLoc} tracked LOC
            </p>
          </div>

          <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-medium text-slate-500">Stale / Diverged Branches</p>
            <p className="mt-2 text-2xl font-bold text-slate-900">
              {branchDrift.staleBranches.length}
              <span className="ml-1.5 text-sm font-normal text-slate-500">
                / {branchDrift.branchesAnalyzed} compared
              </span>
            </p>
            <p className="mt-1 text-xs text-slate-500">
              Compared against <code className="text-slate-700">{branchDrift.mainBranch}</code>
            </p>
          </div>

          <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-medium text-slate-500">Top Bus-Factor Concentration</p>
            {busFactor.topRisk ? (
              <>
                <p className="mt-2 truncate text-base font-bold text-slate-900" title={busFactor.topRisk.file}>
                  {busFactor.topRisk.file}
                </p>
                <p className="mt-1 text-xs text-slate-600">
                  Owner: {busFactor.topRisk.topAuthor} &middot; DOA {busFactor.topRisk.doa} (
                  {(busFactor.topRisk.share * 100).toFixed(1)}%)
                </p>
              </>
            ) : (
              <>
                <p className="mt-2 text-base font-semibold text-slate-700">None detected</p>
                <p className="mt-1 text-xs text-slate-500">No file concentration risk computed.</p>
              </>
            )}
          </div>
        </div>

        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-100/80 px-4 py-2.5 text-xs text-slate-600">
          <span className="font-semibold text-slate-700">Data Source Notice:</span> Metric cards above use
          structured fields from <code className="font-mono">metrics.json</code> ({hotspots.windowDays}-day hotspot window,
          file DOA bus factor, branch drift). Repo-wide commit counts, 7/30-day commit totals, all-time line churn,
          and daily commit timelines appear in the PNG charts and Markdown report below when available.
        </div>
      </section>

      {/* Detailed Tables */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        {/* Bus Factor Files */}
        <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <h3 className="text-base font-semibold text-slate-900">High-Risk Bus Factor Files</h3>
          <p className="mt-0.5 text-xs text-slate-500">
            Degree of Authorship concentration from <code className="font-mono">metrics.json</code>
          </p>
          {busFactor.highRiskFiles.length === 0 ? (
            <p className="mt-4 text-sm text-slate-500">No file-level authorship records available.</p>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="min-w-full divide-y divide-slate-200 text-xs">
                <thead>
                  <tr className="text-left text-slate-500">
                    <th className="py-2 pr-3 font-medium">File</th>
                    <th className="px-2 py-2 font-medium">Top Author</th>
                    <th className="px-2 py-2 font-medium">DOA</th>
                    <th className="px-2 py-2 font-medium">Share</th>
                    <th className="py-2 pl-2 font-medium">Risk</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {busFactor.highRiskFiles.map((entry) => (
                    <tr key={entry.file}>
                      <td className="max-w-[180px] truncate py-2 pr-3 font-mono text-slate-800" title={entry.file}>
                        {entry.file}
                      </td>
                      <td className="px-2 py-2 text-slate-700">{entry.topAuthor}</td>
                      <td className="px-2 py-2 tabular-nums text-slate-700">{entry.doa}</td>
                      <td className="px-2 py-2 tabular-nums text-slate-700">
                        {(entry.share * 100).toFixed(1)}%
                      </td>
                      <td className="py-2 pl-2">
                        <span className={`inline-block rounded-full border px-2 py-0.5 text-[11px] font-medium ${riskClass(entry.riskLevel)}`}>
                          {entry.riskLevel}
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        {/* 30-Day Hotspots */}
        <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <h3 className="text-base font-semibold text-slate-900">
            {hotspots.windowDays}-Day Hotspot Volatility
          </h3>
          <p className="mt-0.5 text-xs text-slate-500">
            Decay-weighted churn scores over the last {hotspots.windowDays} days (<code className="font-mono">&lambda;={hotspots.decayLambda}</code>)
          </p>
          {hotspots.topHotspots.length === 0 ? (
            <p className="mt-4 text-sm text-slate-500">
              No file changes recorded within the {hotspots.windowDays}-day hotspot window.
            </p>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <table className="min-w-full divide-y divide-slate-200 text-xs">
                <thead>
                  <tr className="text-left text-slate-500">
                    <th className="py-2 pr-3 font-medium">File</th>
                    <th className="px-2 py-2 font-medium">Score</th>
                    <th className="px-2 py-2 font-medium">Churn %</th>
                    <th className="px-2 py-2 font-medium">+/- Lines</th>
                    <th className="py-2 pl-2 font-medium">Window Commits</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {hotspots.topHotspots.map((spot) => (
                    <tr key={spot.file}>
                      <td className="max-w-[180px] truncate py-2 pr-3 font-mono text-slate-800" title={spot.file}>
                        {spot.file}
                      </td>
                      <td className="px-2 py-2 tabular-nums font-medium text-slate-900">
                        {spot.hotspotScore}
                      </td>
                      <td className="px-2 py-2 tabular-nums text-slate-700">{spot.churn}%</td>
                      <td className="px-2 py-2 tabular-nums text-slate-700">
                        +{spot.additions} / -{spot.deletions}
                      </td>
                      <td className="py-2 pl-2 tabular-nums text-slate-700">{spot.commitCount}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>

      {/* Branch Drift Table */}
      <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
        <h3 className="text-base font-semibold text-slate-900">Branch Drift & Staleness</h3>
        <p className="mt-0.5 text-xs text-slate-500">
          Non-primary local branches compared against <code className="font-mono">{branchDrift.mainBranch}</code> merge-base
        </p>
        {branchDrift.staleBranches.length === 0 ? (
          <p className="mt-3 text-sm text-slate-500">No diverged or stale branches reported.</p>
        ) : (
          <div className="mt-3 overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200 text-xs">
              <thead>
                <tr className="text-left text-slate-500">
                  <th className="py-2 pr-3 font-medium">Branch</th>
                  <th className="px-2 py-2 font-medium">Drift Score</th>
                  <th className="px-2 py-2 font-medium">Days Since Split</th>
                  <th className="px-2 py-2 font-medium">Main Commits Ahead</th>
                  <th className="px-2 py-2 font-medium">Sync Merges</th>
                  <th className="py-2 pl-2 font-medium">Risk</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {branchDrift.staleBranches.map((br) => (
                  <tr key={br.branch}>
                    <td className="py-2 pr-3 font-mono text-slate-800">{br.branch}</td>
                    <td className="px-2 py-2 tabular-nums font-medium text-slate-900">{br.drift}</td>
                    <td className="px-2 py-2 tabular-nums text-slate-700">{br.daysSinceDivergence}</td>
                    <td className="px-2 py-2 tabular-nums text-slate-700">{br.mainCommitsSince}</td>
                    <td className="px-2 py-2 tabular-nums text-slate-700">{br.syncCommits}</td>
                    <td className="py-2 pl-2">
                      <span className={`inline-block rounded-full border px-2 py-0.5 text-[11px] font-medium ${riskClass(br.riskLevel)}`}>
                        {br.riskLevel}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
