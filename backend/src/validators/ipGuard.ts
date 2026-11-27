import { BlockList, isIP } from 'node:net';
import { SsrfBlockedError } from '../utils/errors';

const IPV4_NON_PUBLIC_BLOCKLIST = new BlockList();
const IPV6_NON_PUBLIC_BLOCKLIST = new BlockList();

// Non-public IPv4 ranges (RFC 1918, loopback, link-local / IMDS, CGNAT, multicast, reserved)
const NON_PUBLIC_IPV4_CIDRS: Array<[string, number]> = [
  ['0.0.0.0', 8],       // "This" network (RFC 1122)
  ['10.0.0.0', 8],      // Private RFC 1918
  ['100.64.0.0', 10],   // Shared / CGNAT (RFC 6598)
  ['127.0.0.0', 8],     // Loopback
  ['169.254.0.0', 16],  // Link-local & AWS IMDS (169.254.169.254)
  ['172.16.0.0', 12],   // Private RFC 1918
  ['192.0.0.0', 24],    // IETF protocol assignments
  ['192.0.2.0', 24],    // TEST-NET-1
  ['192.88.99.0', 24],  // 6to4 relay anycast
  ['192.168.0.0', 16],  // Private RFC 1918
  ['198.18.0.0', 15],   // Benchmarking
  ['198.51.100.0', 24], // TEST-NET-2
  ['203.0.113.0', 24],  // TEST-NET-3
  ['224.0.0.0', 4],     // Multicast
  ['240.0.0.0', 4],     // Reserved & broadcast (255.255.255.255)
];

for (const [net, prefix] of NON_PUBLIC_IPV4_CIDRS) {
  IPV4_NON_PUBLIC_BLOCKLIST.addSubnet(net, prefix, 'ipv4');
}

// Separate IPv6 blocklist prevents ::ffff:0:0/96 from matching native IPv4 lookups in Node BlockList
const NON_PUBLIC_IPV6_CIDRS: Array<[string, number]> = [
  ['::', 128],          // Unspecified
  ['::1', 128],         // Loopback
  ['::ffff:0:0', 96],   // IPv4-mapped IPv6
  ['::', 96],           // IPv4-compatible IPv6
  ['64:ff9b::', 96],    // NAT64 well-known
  ['64:ff9b:1::', 48],  // NAT64 local-use
  ['100::', 64],        // Discard-only
  ['2001::', 32],       // Teredo tunneling
  ['2001:2::', 48],     // Benchmarking
  ['2001:db8::', 32],   // Documentation
  ['2002::', 16],       // 6to4 tunneling
  ['fc00::', 7],        // Unique local address (ULA)
  ['fe80::', 10],       // Link-local
  ['fec0::', 10],       // Deprecated site-local
  ['ff00::', 8],        // Multicast
];

for (const [net, prefix] of NON_PUBLIC_IPV6_CIDRS) {
  IPV6_NON_PUBLIC_BLOCKLIST.addSubnet(net, prefix, 'ipv6');
}

/**
 * Returns true strictly for globally routable unicast IPv4/IPv6 addresses.
 * Rejects malformed IPs, zone IDs (%eth0), loopback, RFC 1918, link-local,
 * cloud metadata, multicast, CGNAT, reserved, and IPv4/IPv6 tunnel transitions.
 */
export function isPublicIp(rawIp: string): boolean {
  if (!rawIp || rawIp.includes('%')) {
    return false;
  }

  const family = isIP(rawIp);
  if (family === 4) {
    return !IPV4_NON_PUBLIC_BLOCKLIST.check(rawIp, 'ipv4');
  }
  if (family === 6) {
    return !IPV6_NON_PUBLIC_BLOCKLIST.check(rawIp, 'ipv6');
  }
  return false;
}

export function assertPublicIp(rawIp: string, context = 'target host'): void {
  if (!isPublicIp(rawIp)) {
    throw new SsrfBlockedError(
      `Destination IP address "${rawIp}" for ${context} is not a permitted public address`,
      { ip: rawIp, context },
    );
  }
}
