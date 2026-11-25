import React from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

export interface MarkdownReportProps {
  summaryMarkdown: string;
}

/**
 * Safely renders summary.md using AST-based ReactMarkdown without raw HTML
 * injection (no rehype-raw, no dangerouslySetInnerHTML).
 */
export function MarkdownReport({ summaryMarkdown }: MarkdownReportProps): React.ReactElement {
  const trimmed = summaryMarkdown.trim();

  return (
    <section
      aria-label="Analysis Markdown report"
      className="rounded-xl border border-slate-200 bg-white p-6 shadow-sm"
    >
      <div className="mb-4 flex items-center justify-between border-b border-slate-100 pb-3">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Analysis Report (summary.md)</h2>
          <p className="text-xs text-slate-500">
            Generated report artifact from the analyzer pipeline (Groq AI insights or deterministic fallback).
          </p>
        </div>
      </div>

      {!trimmed ? (
        <div className="rounded-lg border border-slate-200 bg-slate-50 px-4 py-6 text-center text-sm text-slate-600">
          Report summary artifact is empty or unavailable for this analysis.
        </div>
      ) : (
        <div className="space-y-3 text-sm leading-relaxed text-slate-800">
          <ReactMarkdown
            remarkPlugins={[remarkGfm]}
            components={{
              h1: ({ children }) => (
                <h3 className="mt-4 border-b border-slate-100 pb-1.5 text-xl font-bold text-slate-900">
                  {children}
                </h3>
              ),
              h2: ({ children }) => (
                <h4 className="mt-5 text-base font-semibold text-slate-900">{children}</h4>
              ),
              h3: ({ children }) => (
                <h5 className="mt-3 text-sm font-semibold text-slate-800">{children}</h5>
              ),
              p: ({ children }) => <p className="text-sm text-slate-700">{children}</p>,
              ul: ({ children }) => (
                <ul className="list-disc space-y-1 pl-5 text-sm text-slate-700">{children}</ul>
              ),
              ol: ({ children }) => (
                <ol className="list-decimal space-y-1 pl-5 text-sm text-slate-700">{children}</ol>
              ),
              blockquote: ({ children }) => (
                <blockquote className="border-l-4 border-blue-200 bg-blue-50/50 py-1 pl-3 italic text-slate-700">
                  {children}
                </blockquote>
              ),
              code: ({ className, children }) => {
                const isBlock = Boolean(className);
                if (isBlock) {
                  return (
                    <code className="block overflow-x-auto rounded-lg bg-slate-900 p-3 font-mono text-xs text-slate-100">
                      {children}
                    </code>
                  );
                }
                return (
                  <code className="rounded bg-slate-100 px-1.5 py-0.5 font-mono text-xs text-slate-800">
                    {children}
                  </code>
                );
              },
              pre: ({ children }) => <pre className="my-2 overflow-x-auto">{children}</pre>,
              table: ({ children }) => (
                <div className="my-3 overflow-x-auto">
                  <table className="min-w-full border-collapse border border-slate-200 text-xs">
                    {children}
                  </table>
                </div>
              ),
              th: ({ children }) => (
                <th className="border border-slate-200 bg-slate-50 px-3 py-1.5 text-left font-semibold text-slate-800">
                  {children}
                </th>
              ),
              td: ({ children }) => (
                <td className="border border-slate-200 px-3 py-1.5 text-slate-700">{children}</td>
              ),
              a: ({ href, children }) => (
                <a
                  href={href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-blue-600 underline hover:text-blue-800"
                >
                  {children}
                </a>
              ),
            }}
          >
            {trimmed}
          </ReactMarkdown>
        </div>
      )}
    </section>
  );
}
