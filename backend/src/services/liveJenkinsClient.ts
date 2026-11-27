import { z } from 'zod';
import {
  IJenkinsClient,
  JenkinsArtifactDescriptor,
  JenkinsBuildResult,
  JenkinsBuildStatus,
  JenkinsQueueResolution,
  JenkinsTriggerResult,
  RawArtifactBundle,
} from './jenkinsClient';

const MAX_ARTIFACT_BYTES = 10 * 1024 * 1024;
const MAX_REDIRECTS = 2;
const ARTIFACT_PATH_SAFE_REGEX = /^[A-Za-z0-9._/-]+$/;
const REDIRECT_CODES = new Set([301, 302, 303, 307, 308]);

const CrumbResponseSchema = z.object({
  crumbRequestField: z.string().min(1),
  crumb: z.string().min(1),
});

const QueueItemResponseSchema = z.object({
  cancelled: z.boolean().optional(),
  executable: z
    .object({
      number: z.number().int().positive(),
      url: z.string().min(1).optional(),
    })
    .nullable()
    .optional(),
});

const BuildArtifactEntrySchema = z.object({
  fileName: z.string().min(1),
  relativePath: z.string().min(1),
});

const BuildResponseSchema = z.object({
  building: z.boolean(),
  result: z.enum(['SUCCESS', 'FAILURE', 'ABORTED', 'UNSTABLE']).nullable(),
  duration: z.number().nonnegative().optional(),
  url: z.string().min(1).optional(),
  artifacts: z.array(BuildArtifactEntrySchema).optional(),
});

export interface LiveJenkinsClientConfig {
  baseUrl: string;
  username: string;
  apiToken: string;
  jobName: string;
  requestTimeoutMs?: number;
  maxArtifactBytes?: number;
}

export class JenkinsClientError extends Error {
  public readonly code:
    | 'JENKINS_AUTH_FAILED'
    | 'JENKINS_NOT_FOUND'
    | 'JENKINS_TIMEOUT'
    | 'JENKINS_NETWORK_ERROR'
    | 'JENKINS_INVALID_RESPONSE'
    | 'JENKINS_UNTRUSTED_REDIRECT';

  constructor(code: JenkinsClientError['code'], message: string) {
    super(message);
    this.name = 'JenkinsClientError';
    this.code = code;
  }
}

/**
 * Real Jenkins REST API client scoped strictly to the configured controller origin.
 * Validates all queue/build/redirect URLs against controllerOrigin before sending
 * HTTP Basic credentials, validates response payloads via Zod, enforces bounded
 * timeouts/sizes, and strips sensitive credentials from all errors.
 */
export class LiveJenkinsClient implements IJenkinsClient {
  private readonly controllerOrigin: string;
  private readonly basePath: string;
  private readonly jobName: string;
  private readonly basicAuthHeader: string;
  private readonly secretValues: string[];
  private readonly requestTimeoutMs: number;
  private readonly maxArtifactBytes: number;

  constructor(config: LiveJenkinsClientConfig) {
    let parsed: URL;
    try {
      parsed = new URL(config.baseUrl);
    } catch {
      throw new Error('Invalid Jenkins controller baseUrl');
    }

    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new Error('Jenkins controller baseUrl must use http or https protocol');
    }
    if (parsed.username !== '' || parsed.password !== '') {
      throw new Error('Jenkins controller baseUrl must not embed credentials');
    }
    if (!config.username || !config.apiToken) {
      throw new Error('Jenkins username and apiToken are required');
    }

    this.controllerOrigin = parsed.origin;
    this.basePath = parsed.pathname.replace(/\/+$/, '');
    this.jobName = config.jobName;
    const rawCreds = `${config.username}:${config.apiToken}`;
    const encodedCreds = Buffer.from(rawCreds, 'utf8').toString('base64');
    this.basicAuthHeader = `Basic ${encodedCreds}`;
    this.secretValues = [config.apiToken, encodedCreds, this.basicAuthHeader].filter((s) => s.length >= 4);
    this.requestTimeoutMs = config.requestTimeoutMs ?? 5000;
    this.maxArtifactBytes = config.maxArtifactBytes ?? MAX_ARTIFACT_BYTES;
  }

  public async triggerJob(repositoryUrl: string): Promise<JenkinsTriggerResult> {
    const crumb = await this.fetchCrumb();
    const triggerPath = `${this.basePath}/job/${encodeURIComponent(this.jobName)}/buildWithParameters`;
    const targetUrl = new URL(triggerPath, this.controllerOrigin);

    const headers: Record<string, string> = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    if (crumb !== null) {
      headers[crumb.crumbRequestField] = crumb.crumb;
    }

    const res = await this.executeSameOriginRequest(
      'POST',
      targetUrl,
      headers,
      new URLSearchParams({ REPO_URL: repositoryUrl }).toString(),
    );

    if (res.status < 200 || res.status >= 400) {
      throw new JenkinsClientError(
        'JENKINS_INVALID_RESPONSE',
        `Unexpected HTTP ${res.status} when triggering Jenkins job`,
      );
    }

    const rawLocation = res.headers.get('location');
    if (!rawLocation) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Jenkins trigger response missing Location header');
    }

    const verifiedLocation = this.resolveTrustedControllerUrl(rawLocation);
    const queueMatch = verifiedLocation.pathname.match(/\/queue\/item\/(\d+)\/?$/);
    if (!queueMatch || !queueMatch[1]) {
      throw new JenkinsClientError(
        'JENKINS_INVALID_RESPONSE',
        `Unexpected Jenkins queue Location path "${verifiedLocation.pathname}"`,
      );
    }

    const queueId = Number.parseInt(queueMatch[1], 10);
    if (!Number.isSafeInteger(queueId) || queueId <= 0) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Invalid Jenkins queue ID in Location header');
    }

    return { queueId };
  }

  public async getBuildFromQueue(queueId: number): Promise<JenkinsQueueResolution> {
    const queueUrl = new URL(`${this.basePath}/queue/item/${queueId}/api/json`, this.controllerOrigin);
    const data = await this.fetchJson(queueUrl, QueueItemResponseSchema, 'queue item');

    if (data.cancelled === true) {
      return { resolved: true, cancelled: true, buildNumber: null };
    }

    if (data.executable) {
      if (data.executable.url !== undefined) {
        this.resolveTrustedControllerUrl(data.executable.url);
      }
      return {
        resolved: true,
        cancelled: false,
        buildNumber: data.executable.number,
      };
    }

    return { resolved: false, cancelled: false, buildNumber: null };
  }

  public async getBuildStatus(buildNumber: number): Promise<JenkinsBuildStatus> {
    const result = await this.getBuildResult(buildNumber);
    return {
      building: result.building,
      result: result.result,
      durationMs: result.durationMs,
    };
  }

  public async getBuildResult(buildNumber: number): Promise<JenkinsBuildResult> {
    const buildUrl = new URL(
      `${this.basePath}/job/${encodeURIComponent(this.jobName)}/${buildNumber}/api/json`,
      this.controllerOrigin,
    );
    const data = await this.fetchJson(buildUrl, BuildResponseSchema, 'build metadata');

    if (data.url !== undefined) {
      this.resolveTrustedControllerUrl(data.url);
    }

    const artifacts: JenkinsArtifactDescriptor[] = [];
    for (const art of data.artifacts ?? []) {
      this.assertSafeArtifactRelativePath(art.relativePath);
      artifacts.push({
        fileName: art.fileName,
        relativePath: art.relativePath,
      });
    }

    return {
      building: data.building,
      result: data.result,
      durationMs: data.duration ?? null,
      artifacts,
    };
  }

  public async fetchArtifact(buildNumber: number): Promise<RawArtifactBundle> {
    const buildResult = await this.getBuildResult(buildNumber);
    if (buildResult.building || buildResult.result !== 'SUCCESS') {
      throw new JenkinsClientError(
        'JENKINS_INVALID_RESPONSE',
        `Cannot fetch artifacts for build #${buildNumber} in state building=${String(buildResult.building)}, result=${String(buildResult.result)}`,
      );
    }

    const metricsDesc = this.findArtifactBySuffix(buildResult.artifacts, [
      'target-repo/reports/metrics.json',
      'reports/metrics.json',
      'metrics.json',
    ]);
    const summaryDesc = this.findArtifactBySuffix(buildResult.artifacts, [
      'target-repo/reports/summary.md',
      'reports/summary.md',
      'summary.md',
    ]);

    if (!metricsDesc || !summaryDesc) {
      throw new JenkinsClientError(
        'JENKINS_INVALID_RESPONSE',
        'Required archived artifacts (metrics.json and summary.md) were missing from build output',
      );
    }

    const authorChartDesc = this.findArtifactBySuffix(buildResult.artifacts, [
      'target-repo/reports/charts/commits_per_author.png',
      'reports/charts/commits_per_author.png',
      'commits_per_author.png',
    ]);
    const dailyChartDesc = this.findArtifactBySuffix(buildResult.artifacts, [
      'target-repo/reports/charts/daily_commit_activity.png',
      'reports/charts/daily_commit_activity.png',
      'daily_commit_activity.png',
    ]);

    const metricsJson = await this.downloadArtifactBytes(buildNumber, metricsDesc.relativePath);
    const summaryMarkdown = await this.downloadArtifactBytes(buildNumber, summaryDesc.relativePath);
    const commitsPerAuthorPng = authorChartDesc
      ? await this.downloadArtifactBytes(buildNumber, authorChartDesc.relativePath)
      : null;
    const dailyActivityPng = dailyChartDesc
      ? await this.downloadArtifactBytes(buildNumber, dailyChartDesc.relativePath)
      : null;

    return {
      metricsJson,
      summaryMarkdown,
      commitsPerAuthorPng,
      dailyActivityPng,
    };
  }

  private async fetchCrumb(): Promise<{ crumbRequestField: string; crumb: string } | null> {
    const crumbUrl = new URL(`${this.basePath}/crumbIssuer/api/json`, this.controllerOrigin);
    const res = await this.executeSameOriginRequest('GET', crumbUrl, {}, undefined, true);
    if (res.status === 404) {
      return null;
    }
    if (res.status < 200 || res.status >= 300) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', `Unexpected crumb status HTTP ${res.status}`);
    }
    const bytes = await this.readBoundedBody(res);
    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(bytes.toString('utf8'));
    } catch {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Malformed Jenkins crumb JSON');
    }
    const parsed = CrumbResponseSchema.safeParse(parsedJson);
    if (!parsed.success) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Invalid Jenkins crumb payload');
    }
    return parsed.data;
  }

  private async fetchJson<T>(url: URL, schema: z.ZodType<T>, label: string): Promise<T> {
    const res = await this.executeSameOriginRequest('GET', url);
    const bytes = await this.readBoundedBody(res);
    let decoded: unknown;
    try {
      decoded = JSON.parse(bytes.toString('utf8'));
    } catch {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', `Invalid JSON returned from Jenkins ${label}`);
    }
    const validated = schema.safeParse(decoded);
    if (!validated.success) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', `Jenkins ${label} failed schema validation`);
    }
    return validated.data;
  }

  private async downloadArtifactBytes(buildNumber: number, relativePath: string): Promise<Buffer> {
    this.assertSafeArtifactRelativePath(relativePath);
    const encodedRel = relativePath.split('/').map(encodeURIComponent).join('/');
    const artifactUrl = new URL(
      `${this.basePath}/job/${encodeURIComponent(this.jobName)}/${buildNumber}/artifact/${encodedRel}`,
      this.controllerOrigin,
    );
    const res = await this.executeSameOriginRequest('GET', artifactUrl);
    return this.readBoundedBody(res);
  }

  private findArtifactBySuffix(
    artifacts: JenkinsArtifactDescriptor[],
    candidates: string[],
  ): JenkinsArtifactDescriptor | null {
    for (const suffix of candidates) {
      const match = artifacts.find((a) => a.relativePath === suffix || a.relativePath.endsWith(`/${suffix}`));
      if (match) {
        return match;
      }
    }
    return null;
  }

  private assertSafeArtifactRelativePath(relPath: string): void {
    if (
      !relPath ||
      relPath.startsWith('/') ||
      relPath.includes('\\') ||
      relPath.includes('\0') ||
      !ARTIFACT_PATH_SAFE_REGEX.test(relPath)
    ) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Jenkins artifact path contains disallowed characters');
    }
    const segments = relPath.split('/');
    if (segments.some((seg) => seg === '' || seg === '.' || seg === '..')) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Jenkins artifact path contains traversal segments');
    }
  }

  private resolveTrustedControllerUrl(rawUrl: string): URL {
    let resolved: URL;
    try {
      resolved = new URL(rawUrl, this.controllerOrigin);
    } catch {
      throw new JenkinsClientError('JENKINS_UNTRUSTED_REDIRECT', 'Jenkins returned malformed URL');
    }

    if (resolved.origin !== this.controllerOrigin) {
      throw new JenkinsClientError(
        'JENKINS_UNTRUSTED_REDIRECT',
        `Rejected untrusted Jenkins URL origin "${resolved.origin}"`,
      );
    }

    if (resolved.username !== '' || resolved.password !== '') {
      throw new JenkinsClientError(
        'JENKINS_UNTRUSTED_REDIRECT',
        'Rejected Jenkins URL containing embedded credentials',
      );
    }

    return resolved;
  }

  private async executeSameOriginRequest(
    method: 'GET' | 'POST',
    initialUrl: URL,
    extraHeaders: Record<string, string> = {},
    body?: string,
    allow404 = false,
  ): Promise<Response> {
    let currentUrl = this.resolveTrustedControllerUrl(initialUrl.toString());

    for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
      let response: Response;
      try {
        response = await fetch(currentUrl, {
          method: hop === 0 ? method : 'GET',
          redirect: 'manual',
          signal: AbortSignal.timeout(this.requestTimeoutMs),
          headers: {
            Accept: 'application/json, application/octet-stream;q=0.9',
            Authorization: this.basicAuthHeader,
            ...(hop === 0 ? extraHeaders : {}),
          },
          ...(hop === 0 && body !== undefined ? { body } : {}),
        });
      } catch (err) {
        if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
          throw new JenkinsClientError('JENKINS_TIMEOUT', 'Jenkins request timed out');
        }
        const safeMsg = this.sanitizeMessage(err instanceof Error ? err.message : String(err));
        throw new JenkinsClientError('JENKINS_NETWORK_ERROR', `Jenkins request failed: ${safeMsg}`);
      }

      if (REDIRECT_CODES.has(response.status)) {
        const loc = response.headers.get('location');
        await response.body?.cancel().catch(() => undefined);
        if (!loc) {
          throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', 'Redirect response missing Location header');
        }
        const verifiedNext = this.resolveTrustedControllerUrl(loc);
        // triggerJob POST intentionally returns 201 or 302 to /queue/item/<id>/; preserve queue location directly
        if (method === 'POST' && /\/queue\/item\/\d+\/?$/.test(verifiedNext.pathname)) {
          return response;
        }
        if (hop >= MAX_REDIRECTS) {
          throw new JenkinsClientError('JENKINS_UNTRUSTED_REDIRECT', 'Exceeded same-origin Jenkins redirect limit');
        }
        currentUrl = verifiedNext;
        continue;
      }

      if (response.status === 401 || response.status === 403) {
        await response.body?.cancel().catch(() => undefined);
        throw new JenkinsClientError('JENKINS_AUTH_FAILED', `Jenkins authentication failed (HTTP ${response.status})`);
      }

      if (response.status === 404) {
        if (allow404) {
          await response.body?.cancel().catch(() => undefined);
          return response;
        }
        await response.body?.cancel().catch(() => undefined);
        throw new JenkinsClientError('JENKINS_NOT_FOUND', 'Requested Jenkins job or build was not found');
      }

      if (response.status >= 500) {
        await response.body?.cancel().catch(() => undefined);
        throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', `Jenkins controller returned HTTP ${response.status}`);
      }

      return response;
    }

    throw new JenkinsClientError('JENKINS_UNTRUSTED_REDIRECT', 'Redirect handling failed');
  }

  private async readBoundedBody(response: Response): Promise<Buffer> {
    if (!response.ok) {
      throw new JenkinsClientError('JENKINS_INVALID_RESPONSE', `Unexpected Jenkins HTTP status ${response.status}`);
    }

    const declaredLengthHeader = response.headers.get('content-length');
    if (declaredLengthHeader) {
      const declared = Number.parseInt(declaredLengthHeader, 10);
      if (Number.isFinite(declared) && declared > this.maxArtifactBytes) {
        throw new JenkinsClientError(
          'JENKINS_INVALID_RESPONSE',
          `Jenkins response size ${declared} exceeds max limit (${this.maxArtifactBytes} bytes)`,
        );
      }
    }

    if (!response.body) {
      return Buffer.alloc(0);
    }

    const reader = response.body.getReader();
    const chunks: Buffer[] = [];
    let totalBytes = 0;

    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      totalBytes += value.byteLength;
      if (totalBytes > this.maxArtifactBytes) {
        await reader.cancel().catch(() => undefined);
        throw new JenkinsClientError(
          'JENKINS_INVALID_RESPONSE',
          `Jenkins response exceeded maximum byte limit (${this.maxArtifactBytes} bytes)`,
        );
      }
      chunks.push(Buffer.from(value));
    }

    return Buffer.concat(chunks, totalBytes);
  }

  private sanitizeMessage(message: string): string {
    let cleaned = message;
    for (const secret of this.secretValues) {
      if (secret) {
        cleaned = cleaned.split(secret).join('[REDACTED]');
      }
    }
    cleaned = cleaned.replace(/Basic\s+[A-Za-z0-9+/=]+/gi, 'Basic [REDACTED]');
    return cleaned;
  }
}
