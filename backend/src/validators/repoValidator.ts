import dns from 'node:dns';
import http from 'node:http';
import https from 'node:https';
import type net from 'node:net';
import { z } from 'zod';
import { SsrfBlockedError, ValidationError } from '../utils/errors';
import { assertPublicIp, isPublicIp } from './ipGuard';

export const ALLOWED_GITHUB_HOST = 'github.com';

const GITHUB_OWNER_REGEX = /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/;
const GITHUB_REPO_REGEX = /^[A-Za-z0-9._-]{1,100}$/;
const CONTROL_OR_WHITESPACE_REGEX = /[\s\x00-\x1f\x7f]/;

const RawRepositoryUrlSchema = z
  .string({
    required_error: 'repositoryUrl is required',
    invalid_type_error: 'repositoryUrl must be a string',
  })
  .trim()
  .min(1, 'repositoryUrl cannot be empty')
  .max(2048, 'repositoryUrl exceeds maximum length of 2048 characters');

export interface ValidatedRepositoryUrl {
  canonicalUrl: string;
  owner: string;
  repo: string;
  hostname: string;
}

export interface ResolvedAddress {
  address: string;
  family: 4 | 6;
}

export type DnsLookupAllFn = (
  hostname: string,
  options: dns.LookupAllOptions,
) => Promise<dns.LookupAddress[]>;

export interface HttpsProbeResult {
  statusCode: number;
  location: string | null;
}

export type HttpsProbeFn = (
  url: URL,
  pinnedAddresses: ResolvedAddress[],
  timeoutMs: number,
) => Promise<HttpsProbeResult>;

export interface RepositoryValidationOptions {
  checkDns?: boolean;
  verifyReachability?: boolean;
  dnsLookup?: DnsLookupAllFn;
  httpsProbe?: HttpsProbeFn;
  maxRedirects?: number;
  timeoutMs?: number;
}

const defaultDnsLookupAll: DnsLookupAllFn = (hostname, options) =>
  dns.promises.lookup(hostname, options);

/**
 * Strictly validates syntax and canonicalizes a GitHub repository URL.
 * Rejects credentials, non-HTTPS protocols, non-443 ports, queries, fragments,
 * backslashes, path traversal, IP literals, and any non-github.com hostname.
 */
export function validateRepositoryUrlSyntax(rawInput: unknown): ValidatedRepositoryUrl {
  const schemaResult = RawRepositoryUrlSchema.safeParse(rawInput);
  if (!schemaResult.success) {
    const firstIssue = schemaResult.error.issues[0];
    throw new ValidationError(firstIssue?.message ?? 'Invalid repositoryUrl', schemaResult.error.issues);
  }

  const trimmed = schemaResult.data;

  if (CONTROL_OR_WHITESPACE_REGEX.test(trimmed)) {
    throw new ValidationError('repositoryUrl must not contain internal whitespace or control characters');
  }

  if (trimmed.includes('\\')) {
    throw new ValidationError('repositoryUrl must not contain backslashes');
  }

  if (trimmed.includes('?') || trimmed.includes('#')) {
    throw new ValidationError('repositoryUrl must not contain query parameters or URL fragments');
  }

  const schemeEnd = trimmed.indexOf('://');
  if (schemeEnd === -1) {
    throw new ValidationError('repositoryUrl must be a valid https://github.com/<owner>/<repo> URL');
  }

  const rawScheme = trimmed.slice(0, schemeEnd).toLowerCase();
  if (rawScheme !== 'https') {
    throw new ValidationError('Only https:// protocol is permitted for repositoryUrl');
  }

  const afterScheme = trimmed.slice(schemeEnd + 3);
  const pathStart = afterScheme.indexOf('/');
  const rawAuthority = pathStart === -1 ? afterScheme : afterScheme.slice(0, pathStart);

  if (rawAuthority.includes('@')) {
    throw new ValidationError('Embedded credentials in repositoryUrl are strictly forbidden');
  }

  // Reject trailing dots (e.g. github.com.), brackets, or unexpected port specifications
  const colonIdx = rawAuthority.indexOf(':');
  if (colonIdx !== -1) {
    const rawHost = rawAuthority.slice(0, colonIdx).toLowerCase();
    const rawPort = rawAuthority.slice(colonIdx + 1);
    if (rawHost !== ALLOWED_GITHUB_HOST || rawPort !== '443') {
      throw new ValidationError('Non-standard ports in repositoryUrl are strictly rejected');
    }
  } else if (rawAuthority.toLowerCase() !== ALLOWED_GITHUB_HOST) {
    throw new SsrfBlockedError(
      `Only host "${ALLOWED_GITHUB_HOST}" is permitted; host "${rawAuthority}" is not allowed`,
      { host: rawAuthority },
    );
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new ValidationError('repositoryUrl could not be parsed as a valid URL');
  }

  if (parsed.protocol !== 'https:') {
    throw new ValidationError('Only https:// protocol is permitted for repositoryUrl');
  }

  if (parsed.username !== '' || parsed.password !== '') {
    throw new ValidationError('Embedded credentials in repositoryUrl are strictly forbidden');
  }

  if (parsed.port !== '') {
    throw new ValidationError('Non-standard ports in repositoryUrl are strictly rejected');
  }

  if (parsed.hostname.toLowerCase() !== ALLOWED_GITHUB_HOST) {
    throw new SsrfBlockedError(
      `Only host "${ALLOWED_GITHUB_HOST}" is permitted; host "${parsed.hostname}" is not allowed`,
      { host: parsed.hostname },
    );
  }

  if (parsed.search !== '' || parsed.hash !== '') {
    throw new ValidationError('repositoryUrl must not contain query parameters or URL fragments');
  }

  const decodedLower = parsed.pathname.toLowerCase();
  if (decodedLower.includes('%2e') || decodedLower.includes('%2f') || decodedLower.includes('%5c') || decodedLower.includes('%00')) {
    throw new ValidationError('repositoryUrl path contains disallowed encoded sequences');
  }

  const rawSegments = parsed.pathname.split('/');
  // Strip single leading and optional single trailing slash cleanly
  const segments = rawSegments.filter((seg, idx) => {
    if (seg !== '') {
      return true;
    }
    if (idx === 0 || idx === rawSegments.length - 1) {
      return false;
    }
    return true;
  });

  if (segments.length !== 2) {
    throw new ValidationError(
      'repositoryUrl path must identify a single GitHub repository: https://github.com/<owner>/<repo>',
    );
  }

  const owner = segments[0] ?? '';
  const rawRepo = segments[1] ?? '';

  if (owner === '.' || owner === '..' || rawRepo === '.' || rawRepo === '..' || rawRepo.includes('..')) {
    throw new ValidationError('repositoryUrl path must not contain relative traversal segments');
  }

  if (!GITHUB_OWNER_REGEX.test(owner)) {
    throw new ValidationError('GitHub owner segment has invalid syntax');
  }

  const repo = rawRepo.endsWith('.git') ? rawRepo.slice(0, -4) : rawRepo;
  if (!repo || repo === '.' || repo === '..' || !GITHUB_REPO_REGEX.test(repo)) {
    throw new ValidationError('GitHub repository segment has invalid syntax');
  }

  return {
    canonicalUrl: `https://${ALLOWED_GITHUB_HOST}/${owner}/${repo}`,
    owner,
    repo,
    hostname: ALLOWED_GITHUB_HOST,
  };
}

/**
 * Resolves all A/AAAA DNS records for the target hostname and rejects any response
 * that resolves empty or includes a non-public IP address.
 */
export async function resolveAndVerifyPublicAddresses(
  hostname: string,
  dnsLookup: DnsLookupAllFn = defaultDnsLookupAll,
): Promise<ResolvedAddress[]> {
  let records: dns.LookupAddress[];
  try {
    records = await dnsLookup(hostname, { all: true, verbatim: true });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'DNS lookup error';
    throw new SsrfBlockedError(`DNS resolution failed for "${hostname}": ${message}`, { hostname });
  }

  if (!Array.isArray(records) || records.length === 0) {
    throw new SsrfBlockedError(`DNS resolution returned no addresses for "${hostname}"`, { hostname });
  }

  const validated: ResolvedAddress[] = [];
  for (const record of records) {
    assertPublicIp(record.address, hostname);
    if (record.family !== 4 && record.family !== 6) {
      throw new SsrfBlockedError(`Unsupported address family ${String(record.family)} for "${hostname}"`);
    }
    validated.push({
      address: record.address,
      family: record.family,
    });
  }

  return validated;
}

/**
 * Builds a socket lookup function pinned strictly to pre-validated public IPs
 * so an attacker cannot swap DNS TTL=0 records between validation and TCP connect.
 */
export function createPinnedLookup(
  expectedHostname: string,
  pinnedAddresses: ResolvedAddress[],
): net.LookupFunction {
  if (pinnedAddresses.length === 0) {
    throw new SsrfBlockedError('At least one validated public address is required for pinned lookup');
  }

  return (hostname, options, callback) => {
    if (hostname.toLowerCase() !== expectedHostname.toLowerCase()) {
      const err = new SsrfBlockedError(
        `Blocked unexpected hostname resolution "${hostname}" during pinned TLS connection`,
      );
      if (options.all) {
        process.nextTick(callback, err, []);
      } else {
        process.nextTick(callback, err, '', 4);
      }
      return;
    }

    for (const entry of pinnedAddresses) {
      if (!isPublicIp(entry.address)) {
        const err = new SsrfBlockedError(`Blocked non-public pinned address "${entry.address}"`);
        if (options.all) {
          process.nextTick(callback, err, []);
        } else {
          process.nextTick(callback, err, '', 4);
        }
        return;
      }
    }

    if (options.all) {
      process.nextTick(callback, null, pinnedAddresses);
      return;
    }

    const filtered =
      options.family === 4 || options.family === 6
        ? pinnedAddresses.filter((entry) => entry.family === options.family)
        : pinnedAddresses;
    const chosen = filtered[0] ?? pinnedAddresses[0];
    if (!chosen) {
      const err = new SsrfBlockedError(`No pinned IP matches requested family for "${hostname}"`);
      process.nextTick(callback, err, '', 4);
      return;
    }

    process.nextTick(callback, null, chosen.address, chosen.family);
  };
}

/**
 * Issues a single non-redirecting HTTPS HEAD request pinned to already-validated
 * public IP addresses, and double-checks the connected socket remoteAddress.
 */
export const defaultPinnedHttpsProbe: HttpsProbeFn = (url, pinnedAddresses, timeoutMs) =>
  new Promise<HttpsProbeResult>((resolve, reject) => {
    const pinnedLookup = createPinnedLookup(url.hostname, pinnedAddresses);
    const agent = new https.Agent({
      keepAlive: false,
      lookup: pinnedLookup,
    });

    const req = https.request(
      url,
      {
        method: 'HEAD',
        agent,
        servername: url.hostname,
        timeout: timeoutMs,
        headers: {
          'User-Agent': 'Git-Repo-Analyzer/1.0',
        },
      },
      (res) => {
        res.resume();
        const rawLoc = res.headers.location;
        const location = typeof rawLoc === 'string' ? rawLoc : Array.isArray(rawLoc) ? (rawLoc[0] ?? null) : null;
        resolve({
          statusCode: res.statusCode ?? 0,
          location,
        });
      },
    );

    req.on('socket', (socket) => {
      socket.on('connect', () => {
        if (socket.remoteAddress && !isPublicIp(socket.remoteAddress)) {
          req.destroy(
            new SsrfBlockedError(
              `Connected socket peer address "${socket.remoteAddress}" is non-public; aborting connection`,
            ),
          );
        }
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error(`HTTPS verification request timed out after ${timeoutMs}ms`));
    });

    req.on('error', (err) => {
      reject(err);
    });

    req.end();
  });

const REDIRECT_STATUS_CODES = new Set([301, 302, 303, 307, 308]);

/**
 * Performs full syntactic + DNS public-IP validation, and optionally probes the target
 * with manual redirect inspection + pinned IP lookup to defeat DNS rebinding and
 * redirect-based SSRF bypasses cleanly.
 */
export async function validateRepositoryUrlWithSsrfGuard(
  rawInput: unknown,
  options: RepositoryValidationOptions = {},
): Promise<ValidatedRepositoryUrl> {
  const checkDns = options.checkDns ?? true;
  const verifyReachability = options.verifyReachability ?? false;
  const dnsLookup = options.dnsLookup ?? defaultDnsLookupAll;
  const httpsProbe = options.httpsProbe ?? defaultPinnedHttpsProbe;
  const maxRedirects = options.maxRedirects ?? 3;
  const timeoutMs = options.timeoutMs ?? 5000;

  let current = validateRepositoryUrlSyntax(rawInput);

  if (!checkDns) {
    return current;
  }

  let resolved = await resolveAndVerifyPublicAddresses(current.hostname, dnsLookup);

  if (!verifyReachability) {
    return current;
  }

  let currentUrl = new URL(current.canonicalUrl);
  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const probeRes = await httpsProbe(currentUrl, resolved, timeoutMs);

    if (!REDIRECT_STATUS_CODES.has(probeRes.statusCode)) {
      if (probeRes.statusCode >= 200 && probeRes.statusCode < 400) {
        return current;
      }
      throw new ValidationError(
        `Repository URL verification returned HTTP ${probeRes.statusCode}`,
        { statusCode: probeRes.statusCode, url: current.canonicalUrl },
      );
    }

    if (probeRes.location === null || probeRes.location.trim() === '') {
      throw new SsrfBlockedError('Redirect response missing Location header');
    }

    if (hop >= maxRedirects) {
      throw new SsrfBlockedError(`Exceeded maximum redirect limit of ${maxRedirects}`);
    }

    let nextRaw: string;
    try {
      nextRaw = new URL(probeRes.location, currentUrl).toString();
    } catch {
      throw new SsrfBlockedError(`Malformed redirect Location header "${probeRes.location}"`);
    }

    // Re-validate redirect target syntactically (HTTPS + github.com + safe path) and re-resolve DNS
    current = validateRepositoryUrlSyntax(nextRaw);
    resolved = await resolveAndVerifyPublicAddresses(current.hostname, dnsLookup);
    currentUrl = new URL(current.canonicalUrl);
  }

  throw new SsrfBlockedError('Redirect handling terminated unexpectedly');
}

export function isHttpStatusRedirect(statusCode: number): statusCode is 301 | 302 | 303 | 307 | 308 {
  return REDIRECT_STATUS_CODES.has(statusCode);
}

// Re-export http type unused suppression helper if needed cleanly
export type HttpAgentType = typeof http.Agent;
