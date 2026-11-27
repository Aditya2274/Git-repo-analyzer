#!/usr/bin/env python3
"""Post-activation HTTP loopback & version-consistency health probe for Puppet Phase 5B.

Verifies the backend Express API (/api/health) and NGINX frontend SPA/proxy,
confirming both serve the exact same expected release identifier before Puppet
promotes a release, clears maintenance protection, and prunes older releases.
"""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any


DIRECT_HTTP_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class _ReleaseMetaParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.release_ids: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "meta":
            return
        attr_map = {k.lower(): (v or "") for k, v in attrs}
        if attr_map.get("name", "").strip().lower() == "app-release-id":
            self.release_ids.append(attr_map.get("content", "").strip())


def extract_frontend_release_id(html_text: str) -> str | None:
    parser = _ReleaseMetaParser()
    parser.feed(html_text)
    parser.close()
    non_empty = [val for val in parser.release_ids if val]
    if not non_empty:
        return None
    if len(set(non_empty)) > 1:
        raise ValueError(f"Conflicting app-release-id meta tags in HTML: {non_empty!r}")
    return non_empty[0]


def extract_backend_release_id(headers: dict[str, str] | Any, payload: dict[str, Any]) -> tuple[str | None, str | None]:
    header_rel = None
    if headers is not None:
        raw_hdr = headers.get("X-App-Release")
        if raw_hdr is not None and str(raw_hdr).strip() != "":
            header_rel = str(raw_hdr).strip()

    body_rel_raw = payload.get("releaseId")
    body_rel = str(body_rel_raw).strip() if isinstance(body_rel_raw, str) and body_rel_raw.strip() else None

    if header_rel is not None and body_rel is not None and header_rel != body_rel:
        return None, (
            f"Backend health response header X-App-Release='{header_rel}' disagrees with JSON releaseId='{body_rel}'"
        )
    return header_rel or body_rel, None


def check_json_health(url: str, timeout: float, expected_release: str | None = None) -> tuple[bool, str, str | None]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    try:
        with DIRECT_HTTP_OPENER.open(req, timeout=timeout) as resp:
            status = resp.getcode()
            resp_headers = resp.headers
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code} from {url}", None
    except urllib.error.URLError as exc:
        return False, f"Connection error for {url}: {exc.reason}", None
    except OSError as exc:
        return False, f"Network error for {url}: {exc}", None

    if status != 200:
        return False, f"Unexpected HTTP status {status} from {url} (expected 200)", None

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        return False, f"Invalid JSON response from {url}: {exc}", None

    if not isinstance(payload, dict) or payload.get("status") != "UP":
        return False, f"Health payload at {url} did not report status=UP: {payload!r}", None

    reported_rel, conflict_err = extract_backend_release_id(resp_headers, payload)
    if conflict_err:
        return False, conflict_err, None

    if expected_release is not None and reported_rel != expected_release:
        return (
            False,
            f"Backend runtime release mismatch at {url}: reported='{reported_rel}' != expected='{expected_release}'",
            reported_rel,
        )

    suffix = f", releaseId={reported_rel}" if reported_rel else ""
    return True, f"HTTP 200 OK ({url}, status=UP{suffix})", reported_rel


def check_frontend_root(url: str, timeout: float, expected_release: str | None = None) -> tuple[bool, str, str | None]:
    req = urllib.request.Request(url, headers={"Accept": "text/html,*/*"}, method="GET")
    try:
        with DIRECT_HTTP_OPENER.open(req, timeout=timeout) as resp:
            status = resp.getcode()
            content_type = (resp.headers.get("Content-Type") or "").lower()
            body = resp.read(65536).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code} from {url}", None
    except urllib.error.URLError as exc:
        return False, f"Connection error for {url}: {exc.reason}", None
    except OSError as exc:
        return False, f"Network error for {url}: {exc}", None

    if status != 200:
        return False, f"Unexpected HTTP status {status} from {url} (expected 200)", None

    if "text/html" not in content_type:
        return False, f"Unexpected Content-Type '{content_type}' from {url} (expected text/html)", None

    lowered = body.lower()
    if "<html" not in lowered and "<!doctype html" not in lowered:
        return False, f"Response body from {url} does not contain HTML document markup", None

    try:
        frontend_rel = extract_frontend_release_id(body)
    except ValueError as exc:
        return False, str(exc), None

    if expected_release is not None and frontend_rel != expected_release:
        return (
            False,
            f"Frontend release mismatch at {url}: served app-release-id='{frontend_rel}' != expected='{expected_release}'",
            frontend_rel,
        )

    suffix = f", releaseId={frontend_rel}" if frontend_rel else ""
    return True, f"HTTP 200 text/html OK ({url}{suffix})", frontend_rel


def run_with_retries(check_fn, attempts: int, delay: float) -> int:
    safe_attempts = max(1, attempts)
    safe_delay = max(0.0, delay)
    last_err = "unknown error"
    for attempt in range(1, safe_attempts + 1):
        ok, msg = check_fn()
        if ok:
            print(msg)
            return 0
        last_err = msg
        if attempt < safe_attempts:
            time.sleep(safe_delay)
    print(f"ERROR: Health check failed after {safe_attempts} attempt(s): {last_err}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Puppet Phase 5B HTTP health check")
    sub = parser.add_subparsers(dest="target", required=True)

    p_back = sub.add_parser("backend", help="Verify backend /api/health endpoint")
    p_back.add_argument("--host", default="127.0.0.1")
    p_back.add_argument("--port", type=int, default=3000)
    p_back.add_argument("--path", default="/api/health")
    p_back.add_argument("--expected-release", default=None)
    p_back.add_argument("--timeout", type=float, default=3.0)
    p_back.add_argument("--attempts", type=int, default=5)
    p_back.add_argument("--delay", type=float, default=1.0)

    p_front = sub.add_parser("frontend", help="Verify NGINX frontend SPA and proxied /api/health")
    p_front.add_argument("--host", default="127.0.0.1")
    p_front.add_argument("--port", type=int, default=80)
    p_front.add_argument("--path", default="/")
    p_front.add_argument("--api-health-path", default="/api/health")
    p_front.add_argument("--expected-release", default=None)
    p_front.add_argument("--skip-api-proxy", action="store_true")
    p_front.add_argument("--timeout", type=float, default=3.0)
    p_front.add_argument("--attempts", type=int, default=5)
    p_front.add_argument("--delay", type=float, default=1.0)

    args = parser.parse_args(argv)

    if args.target == "backend":
        url = f"http://{args.host}:{args.port}{args.path}"
        return run_with_retries(
            lambda: check_json_health(url, args.timeout, args.expected_release)[:2],
            args.attempts,
            args.delay,
        )

    if args.target == "frontend":
        root_url = f"http://{args.host}:{args.port}{args.path}"
        api_url = f"http://{args.host}:{args.port}{args.api_health_path}"

        def _check_all() -> tuple[bool, str]:
            ok_root, msg_root, fe_rel = check_frontend_root(root_url, args.timeout, args.expected_release)
            if not ok_root:
                return False, msg_root
            if args.skip_api_proxy:
                return True, msg_root
            ok_api, msg_api, be_rel = check_json_health(api_url, args.timeout, args.expected_release)
            if not ok_api:
                return False, msg_api
            if args.expected_release is not None and fe_rel != be_rel:
                return (
                    False,
                    f"Frontend/backend runtime release mismatch: frontend='{fe_rel}' != backend='{be_rel}'",
                )
            return True, f"{msg_root}; {msg_api}"

        return run_with_retries(_check_all, args.attempts, args.delay)

    return 1


if __name__ == "__main__":
    sys.exit(main())
