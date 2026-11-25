import {
  AnalysisAcceptedResponse,
  AnalysisPublicStatus,
  AnalysisResultsResponse,
  ApiErrorPayload,
  HealthResponse,
} from '../types/analysis';

const ALLOWED_CHART_PATH_REGEX =
  /^\/api\/analyses\/[0-9a-f-]{36}\/charts\/(commits_per_author|daily_commit_activity)\.png$/i;

export class ApiClientError extends Error {
  public readonly statusCode: number;
  public readonly code: string;
  public readonly details: unknown;

  constructor(statusCode: number, code: string, message: string, details: unknown = null) {
    super(message);
    this.name = 'ApiClientError';
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}

export function resolveApiBaseUrl(rawBaseUrl?: string): string {
  const trimmed = (rawBaseUrl ?? '').trim();
  if (!trimmed) {
    return '';
  }
  return trimmed.replace(/\/+$/, '');
}

function defaultMessageForStatus(status: number): string {
  switch (status) {
    case 400:
      return 'Invalid request parameters.';
    case 404:
      return 'Requested analysis or artifact was not found.';
    case 409:
      return 'Analysis results are not ready yet.';
    case 422:
      return 'Submitted repository URL could not be processed.';
    case 500:
      return 'Unexpected server error occurred.';
    case 503:
      return 'Analysis service is temporarily unavailable.';
    default:
      return `Request failed with HTTP ${status}.`;
  }
}

function isApiErrorPayload(value: unknown): value is ApiErrorPayload {
  if (!value || typeof value !== 'object' || !('error' in value)) {
    return false;
  }
  const errObj = (value as { error: unknown }).error;
  return (
    Boolean(errObj) &&
    typeof errObj === 'object' &&
    typeof (errObj as { code?: unknown }).code === 'string' &&
    typeof (errObj as { message?: unknown }).message === 'string'
  );
}

async function parseErrorResponse(response: Response): Promise<ApiClientError> {
  const status = response.status;
  try {
    const contentType = response.headers.get('content-type') ?? '';
    if (contentType.includes('application/json')) {
      const parsed: unknown = await response.json();
      if (isApiErrorPayload(parsed)) {
        return new ApiClientError(
          status,
          parsed.error.code,
          parsed.error.message,
          parsed.error.details ?? null,
        );
      }
    }
  } catch {
    // Fall through to status-based error when body is empty or non-JSON
  }
  return new ApiClientError(status, `HTTP_${status}`, defaultMessageForStatus(status));
}

export interface ApiClientConfig {
  baseUrl?: string;
  fetchImpl?: typeof fetch;
}

export interface AnalysisApiClient {
  getHealth(signal?: AbortSignal): Promise<HealthResponse>;
  submitAnalysis(repositoryUrl: string, signal?: AbortSignal): Promise<AnalysisAcceptedResponse>;
  getAnalysisStatus(analysisId: string, signal?: AbortSignal): Promise<AnalysisPublicStatus>;
  getAnalysisResults(analysisId: string, signal?: AbortSignal): Promise<AnalysisResultsResponse>;
  resolveChartUrl(chartApiPath: string): string;
  fetchChartBlobUrl(chartApiPath: string, signal?: AbortSignal): Promise<string>;
}

export function createApiClient(config: ApiClientConfig = {}): AnalysisApiClient {
  const baseUrl = resolveApiBaseUrl(config.baseUrl ?? import.meta.env.VITE_API_BASE_URL);
  const fetchFn: typeof fetch = config.fetchImpl ?? ((input, init) => globalThis.fetch(input, init));

  async function requestJson<T>(path: string, init: RequestInit = {}): Promise<T> {
    let response: Response;
    try {
      response = await fetchFn(`${baseUrl}${path}`, {
        ...init,
        headers: {
          Accept: 'application/json',
          ...(init.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...init.headers,
        },
      });
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        throw err;
      }
      throw new ApiClientError(
        0,
        'NETWORK_ERROR',
        'Unable to reach the backend API. Check connectivity and try again.',
      );
    }

    if (!response.ok) {
      throw await parseErrorResponse(response);
    }

    try {
      return (await response.json()) as T;
    } catch {
      throw new ApiClientError(
        response.status,
        'INVALID_RESPONSE',
        'Backend returned an unreadable JSON payload.',
      );
    }
  }

  function resolveChartUrl(chartApiPath: string): string {
    if (!ALLOWED_CHART_PATH_REGEX.test(chartApiPath)) {
      throw new ApiClientError(400, 'INVALID_CHART_PATH', 'Unsupported backend chart artifact path.');
    }
    return `${baseUrl}${chartApiPath}`;
  }

  return {
    getHealth: (signal) =>
      requestJson<HealthResponse>('/api/health', signal ? { signal } : {}),

    submitAnalysis: (repositoryUrl, signal) =>
      requestJson<AnalysisAcceptedResponse>('/api/analyses', {
        method: 'POST',
        body: JSON.stringify({ repositoryUrl }),
        ...(signal ? { signal } : {}),
      }),

    getAnalysisStatus: (analysisId, signal) =>
      requestJson<AnalysisPublicStatus>(
        `/api/analyses/${encodeURIComponent(analysisId.trim())}`,
        signal ? { signal } : {},
      ),

    getAnalysisResults: (analysisId, signal) =>
      requestJson<AnalysisResultsResponse>(
        `/api/analyses/${encodeURIComponent(analysisId.trim())}/results`,
        signal ? { signal } : {},
      ),

    resolveChartUrl,

    async fetchChartBlobUrl(chartApiPath: string, signal?: AbortSignal): Promise<string> {
      const targetUrl = resolveChartUrl(chartApiPath);
      let response: Response;
      try {
        response = await fetchFn(targetUrl, {
          headers: { Accept: 'image/png' },
          ...(signal ? { signal } : {}),
        });
      } catch (err) {
        if (err instanceof Error && err.name === 'AbortError') {
          throw err;
        }
        throw new ApiClientError(0, 'NETWORK_ERROR', 'Failed to download chart image from backend.');
      }

      if (!response.ok) {
        throw await parseErrorResponse(response);
      }

      const contentType = response.headers.get('content-type') ?? '';
      if (!contentType.toLowerCase().includes('image/png')) {
        throw new ApiClientError(
          500,
          'INVALID_CHART_TYPE',
          'Chart endpoint did not return a valid PNG image.',
        );
      }

      const blob = await response.blob();
      return URL.createObjectURL(blob);
    },
  };
}

export const apiClient = createApiClient();
