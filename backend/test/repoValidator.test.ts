import assert from 'node:assert/strict';
import dns from 'node:dns';
import test from 'node:test';
import { SsrfBlockedError, ValidationError } from '../src/utils/errors';
import { isPublicIp } from '../src/validators/ipGuard';
import {
  createPinnedLookup,
  defaultPinnedHttpsProbe,
  DnsLookupAllFn,
  HttpsProbeFn,
  resolveAndVerifyPublicAddresses,
  validateRepositoryUrlSyntax,
  validateRepositoryUrlWithSsrfGuard,
} from '../src/validators/repoValidator';

test('isPublicIp rejects non-public IPv4, IPv6, mapped, tunneled, and zone-scoped addresses', () => {
  const blocked = [
    '127.0.0.1',
    '127.255.255.254',
    '10.0.0.1',
    '10.20.30.40',
    '172.16.0.1',
    '172.31.255.254',
    '192.168.0.1',
    '192.168.1.250',
    '169.254.169.254', // AWS IMDS
    '169.254.1.10',
    '0.0.0.0',
    '100.64.0.1', // CGNAT
    '224.0.0.1', // Multicast
    '240.0.0.1', // Reserved
    '255.255.255.255',
    '::',
    '::1',
    'fe80::1',
    'fe80::1%eth0',
    'fc00::1',
    'fd12:3456::1',
    'ff02::1',
    '::ffff:127.0.0.1',
    '::ffff:169.254.169.254',
    '::ffff:7f00:1',
    '::ffff:a9fe:a9fe',
    '2002:7f00:0001::', // 6to4 encoding 127.0.0.1
    '64:ff9b::127.0.0.1', // NAT64
    'not-an-ip',
    '',
  ];

  for (const ip of blocked) {
    assert.equal(isPublicIp(ip), false, `Expected "${ip}" to be blocked`);
  }

  const allowed = [
    '140.82.121.3',
    '140.82.121.4',
    '20.207.73.82',
    '185.199.108.153',
    '2606:50c0:8000::154',
  ];

  for (const ip of allowed) {
    assert.equal(isPublicIp(ip), true, `Expected "${ip}" to be allowed`);
  }
});

test('validateRepositoryUrlSyntax accepts and canonicalizes valid GitHub repository URLs', () => {
  assert.deepEqual(validateRepositoryUrlSyntax('https://github.com/octocat/Hello-World'), {
    canonicalUrl: 'https://github.com/octocat/Hello-World',
    owner: 'octocat',
    repo: 'Hello-World',
    hostname: 'github.com',
  });

  assert.equal(
    validateRepositoryUrlSyntax('https://github.com/octocat/Hello-World.git/').canonicalUrl,
    'https://github.com/octocat/Hello-World',
  );

  assert.equal(
    validateRepositoryUrlSyntax('https://GITHUB.COM:443/aditya-2274/repo_name.1').canonicalUrl,
    'https://github.com/aditya-2274/repo_name.1',
  );
});

test('validateRepositoryUrlSyntax rejects credentials, non-HTTPS, bad ports, queries, fragments, non-GitHub hosts, and traversal', () => {
  const badUrls: unknown[] = [
    '',
    '   ',
    12345,
    'http://github.com/octocat/Hello-World',
    'git://github.com/octocat/Hello-World.git',
    'ssh://git@github.com/octocat/Hello-World.git',
    'file:///etc/passwd',
    'https://user:pass@github.com/octocat/Hello-World',
    'https://token@github.com/octocat/Hello-World',
    'https://github.com:8443/octocat/Hello-World',
    'https://github.com:80/octocat/Hello-World',
    'https://github.com/octocat/Hello-World?tab=readme',
    'https://github.com/octocat/Hello-World?',
    'https://github.com/octocat/Hello-World#readme',
    'https://github.com/octocat/Hello-World#',
    'https://gist.github.com/octocat/12345',
    'https://raw.githubusercontent.com/octocat/Hello-World',
    'https://github.com.evil.com/octocat/Hello-World',
    'https://github.com./octocat/Hello-World',
    'https://127.0.0.1/octocat/Hello-World',
    'https://[::1]/octocat/Hello-World',
    'https://169.254.169.254/latest/meta-data',
    'https://github.com/octocat',
    'https://github.com/octocat/Hello-World/tree/main',
    'https://github.com/octocat/..',
    'https://github.com/octocat/%2e%2e',
    'https://github.com/octocat/Hello-World\\evil',
    'https://github.com/octocat/Hello-World\nmalicious',
  ];

  for (const input of badUrls) {
    assert.throws(
      () => validateRepositoryUrlSyntax(input),
      (err: unknown) => err instanceof ValidationError || err instanceof SsrfBlockedError,
      `Expected syntax validator to reject: ${String(input)}`,
    );
  }
});

test('resolveAndVerifyPublicAddresses blocks empty results, DNS errors, and mixed private records', async () => {
  await assert.rejects(
    () => resolveAndVerifyPublicAddresses('github.com', async () => []),
    SsrfBlockedError,
  );

  await assert.rejects(
    () =>
      resolveAndVerifyPublicAddresses('github.com', async () => {
        throw new Error('ENOTFOUND');
      }),
    SsrfBlockedError,
  );

  await assert.rejects(
    () =>
      resolveAndVerifyPublicAddresses('github.com', async () => [
        { address: '140.82.121.3', family: 4 },
        { address: '127.0.0.1', family: 4 },
      ]),
    SsrfBlockedError,
  );

  const ok = await resolveAndVerifyPublicAddresses('github.com', async () => [
    { address: '140.82.121.3', family: 4 },
  ]);
  assert.deepEqual(ok, [{ address: '140.82.121.3', family: 4 }]);
});

test('createPinnedLookup defeats DNS rebinding by binding solely to validated public IPs', async () => {
  const pinned = createPinnedLookup('github.com', [{ address: '140.82.121.4', family: 4 }]);

  await new Promise<void>((resolve, reject) => {
    pinned('github.com', {}, (err, address, family) => {
      if (err) return reject(err);
      assert.equal(address, '140.82.121.4');
      assert.equal(family, 4);
      resolve();
    });
  });

  await new Promise<void>((resolve, reject) => {
    pinned('github.com', { all: true }, (err, list) => {
      if (err) return reject(err);
      assert.ok(Array.isArray(list));
      assert.deepEqual(list, [{ address: '140.82.121.4', family: 4 }]);
      resolve();
    });
  });

  await new Promise<void>((resolve) => {
    pinned('evil.example.com', {}, (err) => {
      assert.ok(err instanceof SsrfBlockedError);
      resolve();
    });
  });
});

test('defaultPinnedHttpsProbe blocks spoofed loopback target at lookup/socket layer without connecting', async () => {
  await assert.rejects(
    () =>
      defaultPinnedHttpsProbe(
        new URL('https://github.com/octocat/Hello-World'),
        [{ address: '127.0.0.1', family: 4 }],
        1000,
      ),
    SsrfBlockedError,
  );
});

test('validateRepositoryUrlWithSsrfGuard blocks SSRF redirect chains and allows safe GitHub redirects', async () => {
  const publicDns: DnsLookupAllFn = async () => [{ address: '140.82.121.3', family: 4 }];

  // 1. Redirect to AWS IMDS blocked
  const imdsProbe: HttpsProbeFn = async () => ({
    statusCode: 302,
    location: 'http://169.254.169.254/latest/meta-data/',
  });
  await assert.rejects(
    () =>
      validateRepositoryUrlWithSsrfGuard('https://github.com/octocat/Hello-World', {
        checkDns: true,
        verifyReachability: true,
        dnsLookup: publicDns,
        httpsProbe: imdsProbe,
      }),
    (err: unknown) => err instanceof ValidationError || err instanceof SsrfBlockedError,
  );

  // 2. Redirect to external domain blocked
  const externalProbe: HttpsProbeFn = async () => ({
    statusCode: 301,
    location: 'https://internal.corp.local/secret',
  });
  await assert.rejects(
    () =>
      validateRepositoryUrlWithSsrfGuard('https://github.com/octocat/Hello-World', {
        checkDns: true,
        verifyReachability: true,
        dnsLookup: publicDns,
        httpsProbe: externalProbe,
      }),
    SsrfBlockedError,
  );

  // 3. DNS rebinding on second hop (hop 1 public -> redirect to renamed github repo -> hop 2 resolves private IP)
  let dnsCall = 0;
  const rebindingDns: DnsLookupAllFn = async (): Promise<dns.LookupAddress[]> => {
    dnsCall += 1;
    if (dnsCall === 1) {
      return [{ address: '140.82.121.3', family: 4 }];
    }
    return [{ address: '10.0.0.15', family: 4 }];
  };
  const redirectRenameProbe: HttpsProbeFn = async (url) => {
    if (url.pathname === '/octocat/Old-Name') {
      return { statusCode: 301, location: 'https://github.com/octocat/New-Name' };
    }
    return { statusCode: 200, location: null };
  };
  await assert.rejects(
    () =>
      validateRepositoryUrlWithSsrfGuard('https://github.com/octocat/Old-Name', {
        checkDns: true,
        verifyReachability: true,
        dnsLookup: rebindingDns,
        httpsProbe: redirectRenameProbe,
      }),
    SsrfBlockedError,
  );

  // 4. Excessive redirect hops blocked
  const loopingProbe: HttpsProbeFn = async () => ({
    statusCode: 302,
    location: 'https://github.com/octocat/Loop-Repo',
  });
  await assert.rejects(
    () =>
      validateRepositoryUrlWithSsrfGuard('https://github.com/octocat/Loop-Repo', {
        checkDns: true,
        verifyReachability: true,
        dnsLookup: publicDns,
        httpsProbe: loopingProbe,
        maxRedirects: 2,
      }),
    SsrfBlockedError,
  );

  // 5. Valid GitHub rename redirect with public DNS succeeds with updated canonical URL
  const validated = await validateRepositoryUrlWithSsrfGuard('https://github.com/octocat/Old-Name', {
    checkDns: true,
    verifyReachability: true,
    dnsLookup: publicDns,
    httpsProbe: redirectRenameProbe,
  });
  assert.equal(validated.canonicalUrl, 'https://github.com/octocat/New-Name');
});
