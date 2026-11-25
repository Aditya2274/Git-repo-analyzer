import { describe, expect, it, vi } from 'vitest';
import { ApiClientError, createApiClient, resolveApiBaseUrl } from '../src/api/client';

describe('API client', () => {
  it('normalizes configurable API base URLs cleanly', () => {
    expect(resolveApiBaseUrl(undefined)).toBe('');
    expect(resolveApiBaseUrl('   ')).toBe('');
    expect(resolveApiBaseUrl('http://localhost:3000///')).toBe('http://localhost:3000');
  });

  it('calls health, submit, status, and results endpoints cleanly', async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === 'http://backend.local/api/health') {
        return new Response(JSON.stringify({ status: 'UP', timestamp: '2026-11-25T10:00:00Z' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      if (url === 'http://backend.local/api/analyses') {
        return new Response(
          JSON.stringify({
            analysisId: '550e8400-e29b-41d4-a716-446655440000',
            status: 'QUEUED',
            createdAt: '2026-11-25T10:00:00Z',
          }),
          { status: 202, headers: { 'Content-Type': 'application/json' } },
        );
      }
      if (url === 'http://backend.local/api/analyses/550e8400-e29b-41d4-a716-446655440000') {
        return new Response(
          JSON.stringify({
            analysisId: '550e8400-e29b-41d4-a716-446655440000',
            status: 'BUILDING',
            progress: 'Analyzing commits...',
            createdAt: '2026-11-25T10:00:00Z',
            updatedAt: '2026-11-25T10:00:03Z',
            error: null,
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        );
      }
      return new Response('Not found', { status: 404 });
    });

    const client = createApiClient({
      baseUrl: 'http://backend.local/',
      fetchImpl: fetchMock as unknown as typeof fetch,
    });

    const health = await client.getHealth();
    expect(health.status).toBe('UP');

    const accepted = await client.submitAnalysis('https://github.com/octocat/Hello-World');
    expect(accepted.analysisId).toBe('550e8400-e29b-41d4-a716-446655440000');

    const status = await client.getAnalysisStatus(accepted.analysisId);
    expect(status.status).toBe('BUILDING');
  });

  it('parses structured backend error envelopes across HTTP 400/404/409/422/500/503 and network errors', async () => {
    for (const status of [400, 404, 409, 422, 500, 503]) {
      const fetchMock = vi.fn(async () =>
        new Response(
          JSON.stringify({
            error: {
              code: `CODE_${status}`,
              message: `Backend error ${status}`,
              details: { status },
            },
          }),
          { status, headers: { 'Content-Type': 'application/json' } },
        ),
      );
      const client = createApiClient({ baseUrl: '', fetchImpl: fetchMock as unknown as typeof fetch });
      await expect(client.getHealth()).rejects.toMatchObject({
        name: 'ApiClientError',
        statusCode: status,
        code: `CODE_${status}`,
        message: `Backend error ${status}`,
      });
    }

    const downFetch = vi.fn(async () => {
      throw new TypeError('Failed to fetch');
    });
    const downClient = createApiClient({ baseUrl: '', fetchImpl: downFetch as unknown as typeof fetch });
    await expect(downClient.getHealth()).rejects.toMatchObject({
      code: 'NETWORK_ERROR',
    });
  });

  it('validates chart paths and verifies PNG content-type cleanly', async () => {
    const fetchMock = vi.fn(async () =>
      new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), {
        status: 200,
        headers: { 'Content-Type': 'image/png' },
      }),
    );

    const client = createApiClient({ baseUrl: '', fetchImpl: fetchMock as unknown as typeof fetch });
    expect(() => client.resolveChartUrl('https://evil.com/x.png')).toThrow(ApiClientError);
    expect(() => client.resolveChartUrl('/api/analyses/bad/charts/evil.png')).toThrow(ApiClientError);

    const url = await client.fetchChartBlobUrl(
      '/api/analyses/550e8400-e29b-41d4-a716-446655440000/charts/commits_per_author.png',
    );
    expect(url).toMatch(/^blob:/);

    const htmlFetch = vi.fn(async () =>
      new Response('<html>bad</html>', {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      }),
    );
    const badClient = createApiClient({ baseUrl: '', fetchImpl: htmlFetch as unknown as typeof fetch });
    await expect(
      badClient.fetchChartBlobUrl(
        '/api/analyses/550e8400-e29b-41d4-a716-446655440000/charts/commits_per_author.png',
      ),
    ).rejects.toMatchObject({ code: 'INVALID_CHART_TYPE' });
  });
});
