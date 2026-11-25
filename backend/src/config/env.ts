import path from 'node:path';
import { z } from 'zod';

function parseBooleanFlag(value: string | undefined, defaultValue: boolean, name: string): boolean {
  if (value === undefined || value.trim() === '') {
    return defaultValue;
  }
  const normalized = value.trim().toLowerCase();
  if (normalized === 'true') {
    return true;
  }
  if (normalized === 'false') {
    return false;
  }
  throw new Error(`Invalid boolean value for ${name}: "${value}" (expected "true" or "false")`);
}

function parseCorsOrigins(raw: string | undefined, nodeEnv: 'development' | 'test' | 'production'): string[] {
  const effectiveRaw =
    raw === undefined
      ? nodeEnv === 'development'
        ? 'http://localhost:5173'
        : ''
      : raw;

  if (effectiveRaw.trim() === '') {
    return [];
  }

  return effectiveRaw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => {
      let parsed: URL;
      try {
        parsed = new URL(entry);
      } catch {
        throw new Error(`Invalid CORS_ORIGIN entry "${entry}": must be a valid http/https origin`);
      }
      if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || parsed.origin === 'null') {
        throw new Error(`Invalid CORS_ORIGIN protocol for "${entry}": must be http or https`);
      }
      if (parsed.pathname !== '/' || parsed.search !== '' || parsed.hash !== '') {
        throw new Error(`Invalid CORS_ORIGIN "${entry}": must not contain path, query, or fragment`);
      }
      return parsed.origin;
    });
}

const RawEnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  HOST: z.string().trim().min(1).default('127.0.0.1'),
  DATA_DIR: z.string().trim().min(1).optional(),
  CORS_ORIGIN: z.string().optional(),
  SSRF_CHECK_DNS: z.string().optional(),
  ANALYSIS_TIMEOUT_MS: z.coerce.number().int().min(5000).max(3600000).default(600000),
  JENKINS_MOCK_MODE: z.string().optional(),
  JENKINS_URL: z.string().trim().optional(),
  JENKINS_USER: z.string().trim().optional(),
  JENKINS_API_TOKEN: z.string().trim().optional(),
  JENKINS_JOB_NAME: z.string().trim().min(1).default('git-repo-analyzer'),
});

export interface AppConfig {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  host: string;
  dataDir: string;
  corsOrigins: string[];
  ssrfCheckDns: boolean;
  analysisTimeoutMs: number;
  jenkins: {
    mockMode: boolean;
    url: string | null;
    user: string | null;
    apiToken: string | null;
    jobName: string;
  };
}

/**
 * Parses and validates runtime configuration from environment variables.
 * Fails fast on malformed values or unsafe production configuration.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = RawEnvSchema.safeParse(env);
  if (!parsed.success) {
    const details = parsed.error.issues.map((i) => `${i.path.join('.') || 'env'}: ${i.message}`).join('; ');
    throw new Error(`Invalid backend environment configuration: ${details}`);
  }

  const raw = parsed.data;
  const ssrfCheckDns = parseBooleanFlag(raw.SSRF_CHECK_DNS, true, 'SSRF_CHECK_DNS');
  const jenkinsMockMode = parseBooleanFlag(raw.JENKINS_MOCK_MODE, true, 'JENKINS_MOCK_MODE');
  const corsOrigins = parseCorsOrigins(raw.CORS_ORIGIN, raw.NODE_ENV);

  if (raw.NODE_ENV === 'production' && !ssrfCheckDns) {
    throw new Error('SSRF_CHECK_DNS cannot be disabled when NODE_ENV=production');
  }

  const jenkinsUrl = raw.JENKINS_URL && raw.JENKINS_URL.length > 0 ? raw.JENKINS_URL : null;
  const jenkinsUser = raw.JENKINS_USER && raw.JENKINS_USER.length > 0 ? raw.JENKINS_USER : null;
  const jenkinsApiToken = raw.JENKINS_API_TOKEN && raw.JENKINS_API_TOKEN.length > 0 ? raw.JENKINS_API_TOKEN : null;

  if (jenkinsUrl !== null) {
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(jenkinsUrl);
    } catch {
      throw new Error(`Invalid JENKINS_URL: "${jenkinsUrl}"`);
    }
    if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
      throw new Error(`Invalid JENKINS_URL protocol: must be http or https`);
    }
  }

  if (!jenkinsMockMode) {
    if (jenkinsUrl === null || jenkinsUser === null || jenkinsApiToken === null) {
      throw new Error(
        'JENKINS_URL, JENKINS_USER, and JENKINS_API_TOKEN are required when JENKINS_MOCK_MODE=false',
      );
    }
  }

  return {
    nodeEnv: raw.NODE_ENV,
    port: raw.PORT,
    host: raw.HOST,
    dataDir: path.resolve(raw.DATA_DIR ?? path.resolve(process.cwd(), 'data')),
    corsOrigins,
    ssrfCheckDns,
    analysisTimeoutMs: raw.ANALYSIS_TIMEOUT_MS,
    jenkins: {
      mockMode: jenkinsMockMode,
      url: jenkinsUrl,
      user: jenkinsUser,
      apiToken: jenkinsApiToken,
      jobName: raw.JENKINS_JOB_NAME,
    },
  };
}
