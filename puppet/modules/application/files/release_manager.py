#!/usr/bin/env python3
"""Safe release verification, atomic extraction, single-pointer atomic activation,
health-gated promotion, auto-revert on health failure, and pruning tool.

Used exclusively by Puppet's `application` module on EC2 2 (app-server).
No shell command interpolation is permitted; checksum verification invokes
`sha256sum -c --strict` directly without a shell, tarball members are
validated before filesystem writes, and backend/frontend active paths resolve
through one shared atomic pointer (`current -> releases/<version>`) switched
and reverted via a single atomic `os.replace()` syscall.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
from html.parser import HTMLParser
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import Any

VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
NODE_24_RE = re.compile(r"^v?24(\.|$)")


class _HtmlReleaseMetaParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.values: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "meta":
            return
        attr_map = {k.lower(): (v or "") for k, v in attrs}
        if attr_map.get("name", "").strip().lower() == "app-release-id":
            self.values.append(attr_map.get("content", "").strip())


def _extract_html_release_ids(html_text: str) -> list[str]:
    parser = _HtmlReleaseMetaParser()
    parser.feed(html_text)
    parser.close()
    return [v for v in parser.values if v]


def _stamp_frontend_release_meta(release_root: str, version: str) -> None:
    index_path = os.path.join(release_root, "frontend", "dist", "index.html")
    if not os.path.isfile(index_path) or os.path.islink(index_path):
        raise ReleaseError("Cannot stamp release metadata: frontend/dist/index.html missing or symlink")
    try:
        html_text = open(index_path, "r", encoding="utf-8").read()
    except OSError as exc:
        raise ReleaseError(f"Failed reading '{index_path}': {exc}") from exc

    existing = _extract_html_release_ids(html_text)
    if existing:
        if set(existing) != {version}:
            raise ReleaseError(
                f"frontend/dist/index.html carries mismatched app-release-id meta tags {existing!r} (expected '{version}')"
            )
        return

    meta_tag = f'<meta name="app-release-id" content="{version}" />'
    head_close = re.search(r"</head\s*>", html_text, flags=re.IGNORECASE)
    if head_close:
        updated = html_text[:head_close.start()] + f"    {meta_tag}\n  " + html_text[head_close.start():]
    else:
        html_open = re.search(r"<html\b[^>]*>", html_text, flags=re.IGNORECASE)
        if html_open:
            updated = html_text[:html_open.end()] + f"\n  <head>{meta_tag}</head>" + html_text[html_open.end():]
        else:
            updated = f"{meta_tag}\n{html_text}"

    with open(index_path, "w", encoding="utf-8") as fh:
        fh.write(updated)


class ReleaseError(RuntimeError):
    """Fail-closed release validation or staging error."""


def validate_version(version: str) -> str:
    if not VERSION_RE.fullmatch(version) or ".." in version:
        raise ReleaseError(
            f"Invalid release version '{version}': must match [A-Za-z0-9][A-Za-z0-9._-]{{0,127}} without '..'"
        )
    return version


def validate_sha256(digest: str) -> str:
    if not SHA256_RE.fullmatch(digest):
        raise ReleaseError(
            f"Invalid SHA-256 digest '{digest}': must be exactly 64 lowercase hexadecimal characters"
        )
    return digest


def _strip_leading_dot_slash(path_str: str) -> str:
    trimmed = path_str
    while trimmed.startswith("./"):
        trimmed = trimmed[2:]
    return trimmed


def _parse_marker(marker_path: str) -> dict[str, Any] | None:
    if not os.path.isfile(marker_path) or os.path.islink(marker_path):
        return None
    try:
        with open(marker_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def is_extracted(
    releases_dir: str,
    version: str,
    expected_sha256: str,
) -> tuple[bool, str]:
    target_dir = os.path.join(releases_dir, version)
    if os.path.islink(target_dir):
        return False, f"Release path '{target_dir}' must not be a symlink"
    if not os.path.exists(target_dir):
        return False, "Release directory does not exist yet"
    if not os.path.isdir(target_dir):
        return False, f"Release path '{target_dir}' exists and is not a directory"

    for rel_sub in ("backend", os.path.join("backend", "dist"), "frontend", os.path.join("frontend", "dist")):
        sub_path = os.path.join(target_dir, rel_sub)
        if os.path.islink(sub_path) or not os.path.isdir(sub_path):
            return False, f"Extracted release '{target_dir}' has missing or symlinked directory '{rel_sub}'"

    marker_path = os.path.join(target_dir, ".extracted.ok")
    marker = _parse_marker(marker_path)
    if marker is None:
        return False, f"Existing release '{target_dir}' lacks a valid .extracted.ok marker"

    if marker.get("releaseId") != version:
        return (
            False,
            f"Release marker mismatch in '{marker_path}': releaseId='{marker.get('releaseId')}' != '{version}'",
        )

    recorded_sha = marker.get("archiveSha256")
    if recorded_sha != expected_sha256:
        return (
            False,
            f"Immutable release conflict for '{version}': stored SHA-256 '{recorded_sha}' != Hiera expected '{expected_sha256}'",
        )

    try:
        # Never trust .extracted.ok without verifying the on-disk manifest and required entrypoints.
        manifest = validate_extracted_release(target_dir, version)
    except ReleaseError as exc:
        return False, str(exc)

    marker_commit = marker.get("gitCommit")
    manifest_commit = manifest.get("gitCommit") or manifest.get("backendCommit")
    if marker_commit is not None and (not isinstance(marker_commit, str) or marker_commit != manifest_commit):
        return (
            False,
            f"Release marker gitCommit mismatch in '{marker_path}': '{marker_commit}' != '{manifest_commit}'",
        )

    marker_node = marker.get("nodeVersion")
    if marker_node is not None and (not isinstance(marker_node, str) or marker_node != manifest.get("nodeVersion")):
        return (
            False,
            f"Release marker nodeVersion mismatch in '{marker_path}': '{marker_node}' != '{manifest.get('nodeVersion')}'",
        )

    return True, "Release already verified and immutably extracted"


def verify_sidecar_and_checksum(
    staging_dir: str,
    version: str,
    expected_sha256: str,
) -> str:
    archive_name = f"{version}.tar.gz"
    sidecar_name = f"{archive_name}.sha256"
    archive_path = os.path.join(staging_dir, archive_name)
    sidecar_path = os.path.join(staging_dir, sidecar_name)

    for label, path in (("Release archive", archive_path), ("SHA-256 sidecar", sidecar_path)):
        if os.path.islink(path):
            raise ReleaseError(f"{label} '{path}' must not be a symlink")
        if not os.path.isfile(path):
            raise ReleaseError(f"{label} not found at '{path}'")

    if os.path.getsize(archive_path) <= 0:
        raise ReleaseError(f"Release archive '{archive_path}' is empty")

    try:
        with open(sidecar_path, "r", encoding="utf-8") as fh:
            raw_lines = [line.rstrip("\r\n") for line in fh.readlines()]
    except OSError as exc:
        raise ReleaseError(f"Failed reading SHA-256 sidecar '{sidecar_path}': {exc}") from exc

    non_empty = [line for line in raw_lines if line != ""]
    if len(non_empty) != 1:
        raise ReleaseError(
            f"SHA-256 sidecar '{sidecar_path}' must contain exactly 1 non-empty line, found {len(non_empty)}"
        )

    line = non_empty[0]
    sidecar_pattern = re.compile(
        r"^([0-9a-f]{64}) [ *](?:\./)?" + re.escape(archive_name) + r"$"
    )
    match = sidecar_pattern.fullmatch(line)
    if not match:
        raise ReleaseError(
            f"Malformed SHA-256 sidecar line in '{sidecar_path}': expected '<64-hex>  {archive_name}'"
        )

    sidecar_sha = match.group(1)
    if sidecar_sha != expected_sha256:
        raise ReleaseError(
            f"SHA-256 sidecar mismatch for '{archive_name}': sidecar='{sidecar_sha}' != Hiera expected='{expected_sha256}'"
        )

    proc = subprocess.run(
        ["sha256sum", "-c", "--strict", sidecar_name],
        cwd=staging_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise ReleaseError(f"sha256sum -c --strict failed for '{archive_name}': {detail}")

    return archive_path


def _detect_wrapper_prefix(members: list[tarfile.TarInfo], version: str) -> str:
    prefixes: set[str] = set()
    for m in members:
        if m.name.startswith("/") or "\\" in m.name or "\x00" in m.name:
            continue
        cleaned = _strip_leading_dot_slash(m.name)
        if cleaned in ("", "."):
            continue
        top = cleaned.split("/", 1)[0]
        prefixes.add(top)

    if len(prefixes) == 1:
        only_top = next(iter(prefixes))
        if only_top in ("release", version):
            return only_top + "/"
    return ""


def _normalize_member_relpath(raw_name: str, wrapper_prefix: str) -> str:
    if "\x00" in raw_name or "\\" in raw_name:
        raise ReleaseError(f"Illegal control or backslash character in tar member '{raw_name}'")
    if raw_name.startswith("/"):
        raise ReleaseError(f"Absolute path forbidden in tar member '{raw_name}'")

    trimmed = _strip_leading_dot_slash(raw_name)
    if trimmed in ("", "."):
        return ""

    if wrapper_prefix:
        if trimmed == wrapper_prefix.rstrip("/"):
            return ""
        if not trimmed.startswith(wrapper_prefix):
            raise ReleaseError(f"Tar member '{raw_name}' escapes single root wrapper '{wrapper_prefix}'")
        trimmed = trimmed[len(wrapper_prefix):]

    if trimmed.startswith("/"):
        raise ReleaseError(f"Absolute path after wrapper strip in tar member '{raw_name}'")

    parts = [p for p in trimmed.split("/") if p != ""]
    if any(p in (".", "..") for p in parts):
        raise ReleaseError(f"Path traversal component forbidden in tar member '{raw_name}'")

    norm = "/".join(parts)
    if not norm:
        return ""

    allowed = (
        norm == "release-manifest.json"
        or norm == "backend"
        or norm.startswith("backend/")
        or norm == "frontend"
        or norm == "frontend/dist"
        or norm.startswith("frontend/dist/")
    )
    if not allowed:
        raise ReleaseError(
            f"Unexpected tar member path '{norm}': releases may contain only backend/, frontend/dist/, and release-manifest.json"
        )

    prohibited_prefixes = (
        "backend/.env",
        "backend/.git",
        "backend/src",
        "backend/test",
    )
    for prefix in prohibited_prefixes:
        if norm == prefix or norm.startswith(prefix + "/") or (prefix == "backend/.env" and norm.startswith("backend/.env.")):
            raise ReleaseError(
                f"Prohibited development/secret path '{norm}' rejected inside release archive"
            )

    return norm


def _resolve_relative_symlink_within_backend(
    backend_root: str, link_rel: str, max_hops: int = 40
) -> None:
    hops = 0
    pending = [p for p in link_rel.split("/") if p]
    resolved_parts: list[str] = []
    while pending:
        part = pending.pop(0)
        if part == ".":
            continue
        if part == "..":
            if not resolved_parts:
                raise ReleaseError(
                    f"Symlink chain escapes backend/ sandbox from '{link_rel}'"
                )
            resolved_parts.pop()
            continue
        resolved_parts.append(part)
        cur_disk = os.path.join(backend_root, *resolved_parts)
        if os.path.islink(cur_disk):
            hops += 1
            if hops > max_hops:
                raise ReleaseError(
                    f"Symlink loop or excessive symlink depth detected at '{link_rel}'"
                )
            target = os.readlink(cur_disk)
            if not target or target.startswith("/") or "\\" in target or "\x00" in target:
                raise ReleaseError(
                    f"Unsafe symlink target '{target}' encountered while resolving '{link_rel}'"
                )
            resolved_parts.pop()
            pending = [p for p in target.split("/") if p] + pending


def _verify_backend_symlinks_sandbox(dest_dir: str) -> None:
    backend_root = os.path.realpath(os.path.join(dest_dir, "backend"))
    if not os.path.isdir(backend_root):
        return
    for cur_dir, dirs, files in os.walk(backend_root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(cur_dir, backend_root)
        for name in dirs + files:
            full_path = os.path.join(cur_dir, name)
            if os.path.islink(full_path):
                link_rel = name if rel_dir == "." else posixpath.join(rel_dir.replace(os.sep, "/"), name)
                _resolve_relative_symlink_within_backend(backend_root, link_rel)


def _validate_and_extract_archive(archive_path: str, version: str, dest_dir: str) -> dict[str, Any]:
    try:
        tar_ctx = tarfile.open(archive_path, mode="r:gz")
    except (OSError, tarfile.TarError) as exc:
        raise ReleaseError(f"Failed opening gzip tar archive '{archive_path}': {exc}") from exc

    dest_real = os.path.realpath(dest_dir)

    with tar_ctx as tar:
        members = tar.getmembers()
        if not members:
            raise ReleaseError(f"Release archive '{archive_path}' contains no tar members")

        wrapper_prefix = _detect_wrapper_prefix(members, version)
        validated: list[tuple[tarfile.TarInfo, str]] = []
        seen_paths: set[str] = set()
        non_dir_paths: set[str] = set()
        regular_backend_files: set[str] = set()

        for member in members:
            rel = _normalize_member_relpath(member.name, wrapper_prefix)
            if not rel:
                if not member.isdir():
                    raise ReleaseError(
                        f"Archive root entry '{member.name}' must be a directory (got type={member.type!r})"
                    )
                continue

            if rel in seen_paths:
                raise ReleaseError(f"Duplicate tar member path '{rel}' rejected")

            if member.issym():
                if not rel.startswith("backend/"):
                    raise ReleaseError(
                        f"Symlink forbidden outside backend/: '{rel}' -> '{member.linkname}'"
                    )
                if not member.linkname or member.linkname.startswith("/") or "\\" in member.linkname or "\x00" in member.linkname:
                    raise ReleaseError(
                        f"Unsafe symlink target in tar member '{rel}': '{member.linkname}'"
                    )
                resolved_target = posixpath.normpath(
                    posixpath.join(posixpath.dirname(rel), member.linkname)
                )
                if resolved_target == ".." or resolved_target.startswith("../") or not (
                    resolved_target == "backend" or resolved_target.startswith("backend/")
                ):
                    raise ReleaseError(
                        f"Escaping symlink target forbidden: '{rel}' -> '{member.linkname}' (resolves to '{resolved_target}')"
                    )
                non_dir_paths.add(rel)
            elif member.islnk():
                if not rel.startswith("backend/"):
                    raise ReleaseError(f"Hardlink forbidden outside backend/: '{rel}'")
                link_norm = _normalize_member_relpath(member.linkname, wrapper_prefix)
                if not link_norm.startswith("backend/") or link_norm not in regular_backend_files:
                    raise ReleaseError(
                        f"Unsafe hardlink target '{member.linkname}' in tar member '{rel}': must reference a previously validated regular file inside backend/"
                    )
                non_dir_paths.add(rel)
            elif member.isreg():
                non_dir_paths.add(rel)
                if rel.startswith("backend/"):
                    regular_backend_files.add(rel)
            elif not member.isdir():
                raise ReleaseError(
                    f"Unsupported special file type in tar member '{rel}' (type={member.type!r})"
                )

            seen_paths.add(rel)
            validated.append((member, rel))

        # Verify no parent prefix of any path is a file/symlink/hardlink
        for _, rel in validated:
            parent = posixpath.dirname(rel)
            while parent:
                if parent in non_dir_paths:
                    raise ReleaseError(
                        f"Path hierarchy collision in tar archive: non-directory '{parent}' cannot contain '{rel}'"
                    )
                parent = posixpath.dirname(parent)

        # Pass 1: extract directories & regular files first
        pending_links: list[tuple[tarfile.TarInfo, str]] = []
        for member, rel in validated:
            out_path = os.path.join(dest_dir, rel)
            if member.isdir():
                os.makedirs(out_path, exist_ok=True)
            elif member.isreg():
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                if os.path.realpath(os.path.dirname(out_path)) != dest_real and not os.path.realpath(
                    os.path.dirname(out_path)
                ).startswith(dest_real + os.sep):
                    raise ReleaseError(f"Extracted directory '{out_path}' escapes '{dest_real}'")
                src = tar.extractfile(member)
                if src is None:
                    raise ReleaseError(f"Unable to read regular tar member '{rel}'")
                with src, open(out_path, "wb") as out_fh:
                    shutil.copyfileobj(src, out_fh)
                mode = (
                    0o750
                    if (
                        rel.startswith("backend/")
                        and (
                            member.mode & 0o111
                            or rel.startswith("backend/node_modules/.bin/")
                            or rel.endswith(".sh")
                        )
                    )
                    else 0o640
                )
                os.chmod(out_path, mode)
            else:
                pending_links.append((member, rel))

        # Pass 2: create validated internal hardlinks BEFORE symlinks, then verify chained symlink sandbox
        backend_real = os.path.realpath(os.path.join(dest_dir, "backend"))
        hardlinks = [(m, r) for m, r in pending_links if m.islnk()]
        symlinks = [(m, r) for m, r in pending_links if m.issym()]

        for member, rel in hardlinks:
            out_path = os.path.join(dest_dir, rel)
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            if os.path.lexists(out_path):
                raise ReleaseError(f"Collision creating hardlink '{rel}' over existing path")
            link_rel = _normalize_member_relpath(member.linkname, wrapper_prefix)
            target_path = os.path.join(dest_dir, link_rel)
            target_real = os.path.realpath(target_path)
            if (
                not target_real.startswith(backend_real + os.sep)
                or not os.path.isfile(target_path)
                or os.path.islink(target_path)
            ):
                raise ReleaseError(f"Hardlink target '{link_rel}' invalid for '{rel}'")
            os.link(target_path, out_path)

        for member, rel in symlinks:
            out_path = os.path.join(dest_dir, rel)
            os.makedirs(os.path.dirname(out_path), exist_ok=True)
            if os.path.lexists(out_path):
                raise ReleaseError(f"Collision creating symlink '{rel}' over existing path")
            os.symlink(member.linkname, out_path)

        _verify_backend_symlinks_sandbox(dest_dir)

    _stamp_frontend_release_meta(dest_dir, version)
    return validate_extracted_release(dest_dir, version)


def validate_extracted_release(release_root: str, version: str) -> dict[str, Any]:
    manifest_path = os.path.join(release_root, "release-manifest.json")
    if not os.path.isfile(manifest_path) or os.path.islink(manifest_path):
        raise ReleaseError(f"Missing required release-manifest.json in '{release_root}'")

    try:
        with open(manifest_path, "r", encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise ReleaseError(f"Invalid release-manifest.json: {exc}") from exc

    if not isinstance(manifest, dict):
        raise ReleaseError("release-manifest.json must be a JSON object")

    if "archiveSha256" in manifest:
        raise ReleaseError(
            "Self-referential 'archiveSha256' key inside release-manifest.json is forbidden; use external .sha256 sidecar"
        )

    if manifest.get("releaseId") != version:
        raise ReleaseError(
            f"release-manifest.json releaseId '{manifest.get('releaseId')}' does not match expected version '{version}'"
        )

    built_at = manifest.get("builtAt") or manifest.get("builtAtUtc")
    if not isinstance(built_at, str) or not built_at.strip():
        raise ReleaseError("release-manifest.json missing non-empty 'builtAt' or 'builtAtUtc'")

    commit_ref = manifest.get("gitCommit") or manifest.get("backendCommit")
    if not isinstance(commit_ref, str) or not commit_ref.strip():
        raise ReleaseError("release-manifest.json missing non-empty 'gitCommit' or 'backendCommit'")

    node_ver = manifest.get("nodeVersion")
    if not isinstance(node_ver, str) or not NODE_24_RE.match(node_ver.strip()):
        raise ReleaseError(
            f"Incompatible release nodeVersion '{node_ver}': Node.js 24 LTS is required"
        )

    required_dirs = (
        "backend",
        "backend/dist",
        "backend/node_modules",
        "frontend",
        "frontend/dist",
    )
    for rel_dir in required_dirs:
        full_dir = os.path.join(release_root, rel_dir)
        if not os.path.isdir(full_dir) or os.path.islink(full_dir):
            raise ReleaseError(f"Extracted release missing required non-symlink directory '{rel_dir}'")

    required_files = (
        "backend/dist/server.js",
        "backend/package.json",
        "backend/package-lock.json",
        "frontend/dist/index.html",
    )
    for rel_file in required_files:
        full_path = os.path.join(release_root, rel_file)
        if not os.path.isfile(full_path) or os.path.islink(full_path):
            raise ReleaseError(f"Extracted release missing required regular file '{rel_file}'")

    index_path = os.path.join(release_root, "frontend", "dist", "index.html")
    try:
        index_html = open(index_path, "r", encoding="utf-8", errors="replace").read()
    except OSError as exc:
        raise ReleaseError(f"Failed validating '{index_path}': {exc}") from exc
    meta_ids = _extract_html_release_ids(index_html)
    if meta_ids and set(meta_ids) != {version}:
        raise ReleaseError(
            f"Extracted frontend/dist/index.html meta app-release-id {meta_ids!r} does not match expected '{version}'"
        )

    return manifest


def _resolve_uid_gid(user: str, group: str) -> tuple[int, int]:
    import grp
    import pwd

    return pwd.getpwnam(user).pw_uid, grp.getgrnam(group).gr_gid


def _apply_permissions_tree(
    release_root: str,
    backend_owner: str,
    backend_group: str,
    frontend_owner: str,
    frontend_group: str,
    apply_chown: bool,
) -> None:
    os.chmod(release_root, 0o755)
    manifest_path = os.path.join(release_root, "release-manifest.json")
    os.chmod(manifest_path, 0o644)

    if apply_chown:
        root_uid, root_gid = _resolve_uid_gid("root", "root")
        os.chown(release_root, root_uid, root_gid)
        os.chown(manifest_path, root_uid, root_gid)
        b_uid, b_gid = _resolve_uid_gid(backend_owner, backend_group)
        f_uid, f_gid = _resolve_uid_gid(frontend_owner, frontend_group)
    else:
        b_uid = b_gid = f_uid = f_gid = -1

    backend_root = os.path.join(release_root, "backend")
    for cur_dir, dirs, files in os.walk(backend_root, topdown=True, followlinks=False):
        os.chmod(cur_dir, 0o750)
        if apply_chown:
            os.lchown(cur_dir, b_uid, b_gid)
        rel_dir = os.path.relpath(cur_dir, backend_root)
        for name in dirs + files:
            path = os.path.join(cur_dir, name)
            if os.path.islink(path):
                if apply_chown:
                    os.lchown(path, b_uid, b_gid)
                continue
            if os.path.isfile(path):
                cur_mode = stat.S_IMODE(os.lstat(path).st_mode)
                is_exec = bool(cur_mode & 0o111) or rel_dir.startswith("node_modules/.bin") or name.endswith(".sh")
                os.chmod(path, 0o750 if is_exec else 0o640)
                if apply_chown:
                    os.lchown(path, b_uid, b_gid)

    frontend_root = os.path.join(release_root, "frontend")
    os.chmod(frontend_root, 0o750)
    if apply_chown:
        os.lchown(frontend_root, f_uid, f_gid)

    frontend_dist = os.path.join(frontend_root, "dist")
    for cur_dir, dirs, files in os.walk(frontend_dist, topdown=True, followlinks=False):
        os.chmod(cur_dir, 0o750)
        if apply_chown:
            os.lchown(cur_dir, f_uid, f_gid)
        for name in files:
            path = os.path.join(cur_dir, name)
            if os.path.islink(path):
                raise ReleaseError(f"Symlink forbidden in frontend/dist: '{path}'")
            os.chmod(path, 0o640)
            if apply_chown:
                os.lchown(path, f_uid, f_gid)


def _is_pid_dead(pid_text: str) -> bool:
    if not pid_text.isdigit():
        return False
    pid = int(pid_text)
    if pid <= 0 or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


def _cleanup_dead_pid_temps(directory: str, prefix: str, *, is_dir: bool) -> None:
    if not os.path.isdir(directory):
        return
    try:
        entries = os.listdir(directory)
    except OSError:
        return
    for name in entries:
        if not name.startswith(prefix):
            continue
        remainder = name[len(prefix):]
        # Format: <prefix><pid>-<rand> or <prefix><pid>
        pid_part = remainder.split("-", 1)[0]
        if not _is_pid_dead(pid_part):
            continue
        cand = os.path.join(directory, name)
        try:
            if is_dir:
                if os.path.isdir(cand) and not os.path.islink(cand):
                    shutil.rmtree(cand, ignore_errors=True)
            else:
                if os.path.islink(cand) or os.path.isfile(cand):
                    os.unlink(cand)
        except OSError:
            pass


def prepare_release(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)

    already_ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    target_dir = os.path.join(args.releases_dir, version)
    if already_ok:
        print(f"Release {version} already extracted cleanly at {target_dir}")
        return 0
    if os.path.exists(target_dir) or os.path.islink(target_dir):
        raise ReleaseError(reason)

    archive_path = verify_sidecar_and_checksum(args.staging_dir, version, expected_sha256)

    os.makedirs(args.releases_dir, exist_ok=True)
    tmp_prefix = f".tmp-{version}-"
    _cleanup_dead_pid_temps(args.releases_dir, tmp_prefix, is_dir=True)
    tmp_dir = tempfile.mkdtemp(prefix=f"{tmp_prefix}{os.getpid()}-", dir=args.releases_dir)
    verified_copy_path = os.path.join(tmp_dir, ".verified-release.tar.gz")
    renamed = False
    try:
        # Eliminate staging TOCTOU: open with O_NOFOLLOW, verify regular file, copy
        # into root-owned tmp_dir while recomputing SHA-256 against Hiera digest.
        fd = os.open(archive_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            st_info = os.fstat(fd)
            if not stat.S_ISREG(st_info.st_mode):
                raise ReleaseError(f"Release archive '{archive_path}' must be a regular file")
            hasher = hashlib.sha256()
            with os.fdopen(fd, "rb") as src_fh, open(verified_copy_path, "wb") as dst_fh:
                fd = -1
                while True:
                    chunk = src_fh.read(1024 * 1024)
                    if not chunk:
                        break
                    hasher.update(chunk)
                    dst_fh.write(chunk)
        finally:
            if fd >= 0:
                os.close(fd)

        actual_digest = hasher.hexdigest()
        if actual_digest != expected_sha256:
            raise ReleaseError(
                f"Staging archive digest mismatch while reading '{archive_path}': got '{actual_digest}' != Hiera expected '{expected_sha256}'"
            )

        manifest = _validate_and_extract_archive(verified_copy_path, version, tmp_dir)
        os.unlink(verified_copy_path)
        _apply_permissions_tree(
            tmp_dir,
            backend_owner=args.backend_owner,
            backend_group=args.backend_group,
            frontend_owner=args.frontend_owner,
            frontend_group=args.frontend_group,
            apply_chown=args.chown,
        )

        marker_path = os.path.join(tmp_dir, ".extracted.ok")
        commit_val = manifest.get("gitCommit") or manifest.get("backendCommit") or ""
        marker_payload = {
            "releaseId": version,
            "archiveSha256": expected_sha256,
            "gitCommit": commit_val,
            "nodeVersion": manifest["nodeVersion"],
            "extractedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        with open(marker_path, "w", encoding="utf-8") as fh:
            json.dump(marker_payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(marker_path, 0o644)
        if args.chown:
            root_uid, root_gid = _resolve_uid_gid("root", "root")
            os.chown(marker_path, root_uid, root_gid)

        os.rename(tmp_dir, target_dir)
        renamed = True
    finally:
        if not renamed and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)

    print(f"Verified and atomically extracted release {version} to {target_dir}")
    return 0


def _load_state(state_file: str) -> dict[str, Any]:
    if not os.path.isfile(state_file) or os.path.islink(state_file):
        return {}
    try:
        with open(state_file, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_state_atomic(state_file: str, state: dict[str, Any]) -> None:
    state_parent = os.path.dirname(os.path.abspath(state_file))
    os.makedirs(state_parent, exist_ok=True)
    state_prefix = ".release-state-"
    _cleanup_dead_pid_temps(state_parent, state_prefix, is_dir=False)
    fd, tmp_state = tempfile.mkstemp(prefix=f"{state_prefix}{os.getpid()}-", dir=state_parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_state, 0o644)
        os.replace(tmp_state, state_file)
    except Exception:
        if os.path.exists(tmp_state):
            os.unlink(tmp_state)
        raise


def _resolve_current_link(args: argparse.Namespace) -> str:
    explicit = getattr(args, "current_link", None)
    if explicit:
        return explicit
    return os.path.join(os.path.dirname(os.path.abspath(args.backend_link)), "current")


def _symlink_exact_target(link_path: str, expected_target: str) -> bool:
    if not os.path.islink(link_path):
        return False
    return os.readlink(link_path) == expected_target


def _symlink_points_to(link_path: str, expected_target: str) -> bool:
    if not os.path.islink(link_path):
        return False
    return os.path.realpath(link_path) == os.path.realpath(expected_target)


def _atomic_symlink_replace(link_path: str, target_path: str, owner: str | None = None, group: str | None = None) -> None:
    parent_dir = os.path.dirname(os.path.abspath(link_path))
    os.makedirs(parent_dir, exist_ok=True)
    if os.path.lexists(link_path) and not os.path.islink(link_path):
        raise ReleaseError(f"Active link path '{link_path}' exists and is not a symlink")
    tmp_prefix = f".tmp-link-{os.path.basename(link_path)}-"
    _cleanup_dead_pid_temps(parent_dir, tmp_prefix, is_dir=False)
    tmp_link = os.path.join(parent_dir, f"{tmp_prefix}{os.getpid()}")
    if os.path.lexists(tmp_link):
        os.unlink(tmp_link)
    try:
        os.symlink(target_path, tmp_link)
        if owner and group:
            uid, gid = _resolve_uid_gid(owner, group)
            os.lchown(tmp_link, uid, gid)
        os.replace(tmp_link, link_path)
    except Exception:
        if os.path.lexists(tmp_link):
            os.unlink(tmp_link)
        raise


def _active_pair_matches(
    releases_dir: str,
    version: str,
    current_link: str,
    backend_link: str,
    frontend_link: str,
) -> bool:
    target_dir = os.path.join(releases_dir, version)
    expected_backend = os.path.join(current_link, "backend")
    expected_frontend = os.path.join(current_link, "frontend", "dist")
    return (
        _symlink_points_to(current_link, target_dir)
        and _symlink_exact_target(backend_link, expected_backend)
        and _symlink_exact_target(frontend_link, expected_frontend)
        and _symlink_points_to(backend_link, os.path.join(target_dir, "backend"))
        and _symlink_points_to(frontend_link, os.path.join(target_dir, "frontend", "dist"))
    )


def _resolve_active_release_id(releases_dir: str, link_path: str, expected_suffix: str) -> str | None:
    if not os.path.islink(link_path):
        return None
    resolved = os.path.realpath(link_path)
    releases_real = os.path.realpath(releases_dir)
    if not resolved.startswith(releases_real + os.sep):
        return None
    rel = os.path.relpath(resolved, releases_real)
    parts = rel.split(os.sep)
    if not parts or not VERSION_RE.fullmatch(parts[0]):
        return None
    actual_suffix = os.sep.join(parts[1:]) if len(parts) > 1 else ""
    if actual_suffix != expected_suffix:
        return None
    return parts[0]


def is_active(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    ok, _ = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        return 1
    current_link = _resolve_current_link(args)
    return 0 if _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link) else 1


def _validate_link_path_safe(link_path: str) -> None:
    if os.path.lexists(link_path) and not os.path.islink(link_path):
        raise ReleaseError(f"Active link path '{link_path}' exists and is not a symlink")


def _ensure_invariant_pair_links(
    releases_dir: str,
    current_link: str,
    backend_link: str,
    frontend_link: str,
    b_own: tuple[str | None, str | None],
    f_own: tuple[str | None, str | None],
) -> None:
    """Ensure backend_link and frontend_link are static pointers into current_link.

    Once established, switching active releases mutates ONLY current_link via one atomic
    os.replace() syscall, making mixed backend/frontend releases impossible under SIGKILL.
    """
    _validate_link_path_safe(current_link)
    _validate_link_path_safe(backend_link)
    _validate_link_path_safe(frontend_link)

    expected_backend = os.path.join(current_link, "backend")
    expected_frontend = os.path.join(current_link, "frontend", "dist")

    backend_ok = _symlink_exact_target(backend_link, expected_backend)
    frontend_ok = _symlink_exact_target(frontend_link, expected_frontend)
    if backend_ok and frontend_ok:
        return

    # If migrating from an older paired direct-symlink layout before current_link existed,
    # point current_link at that existing release first so backend & frontend stay aligned.
    if not os.path.lexists(current_link):
        legacy_b = _resolve_active_release_id(releases_dir, backend_link, "backend")
        legacy_f = _resolve_active_release_id(releases_dir, frontend_link, os.path.join("frontend", "dist"))
        if legacy_b and legacy_b == legacy_f:
            _atomic_symlink_replace(current_link, os.path.join(releases_dir, legacy_b), *b_own)

    if not backend_ok:
        _atomic_symlink_replace(backend_link, expected_backend, *b_own)
    if not frontend_ok:
        _atomic_symlink_replace(frontend_link, expected_frontend, *f_own)


def activate_release(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        raise ReleaseError(f"Cannot activate unverified release '{version}': {reason}")

    current_link = _resolve_current_link(args)
    target_dir = os.path.join(args.releases_dir, version)

    b_own = ("root", "root") if args.chown else (None, None)
    f_own = (args.frontend_owner, args.frontend_group) if args.chown else (None, None)
    _ensure_invariant_pair_links(
        args.releases_dir,
        current_link,
        args.backend_link,
        args.frontend_link,
        b_own,
        f_own,
    )

    state = _load_state(args.state_file)
    state["pendingActivation"] = {
        "releaseId": version,
        "archiveSha256": expected_sha256,
        "serviceSynced": False,
        "activatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    _write_state_atomic(args.state_file, state)

    # Single atomic pointer replacement switching both backend & frontend simultaneously.
    _atomic_symlink_replace(current_link, target_dir, *b_own)

    print(f"Atomically switched shared release pointer {current_link} -> {target_dir} ({version})")
    return 0


def is_service_synced(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    current_link = _resolve_current_link(args)
    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        return 1
    state = _load_state(args.state_file)
    pending = state.get("pendingActivation")
    if (
        isinstance(pending, dict)
        and pending.get("releaseId") == version
        and pending.get("archiveSha256") == expected_sha256
    ):
        return 0 if pending.get("serviceSynced") is True else 1
    current = state.get("currentKnownGood")
    if (
        isinstance(current, dict)
        and current.get("releaseId") == version
        and current.get("archiveSha256") == expected_sha256
    ):
        return 0
    return 1


def mark_service_synced(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    state = _load_state(args.state_file)
    pending = state.get("pendingActivation")
    if not isinstance(pending, dict) or pending.get("releaseId") != version or pending.get("archiveSha256") != expected_sha256:
        pending = {
            "releaseId": version,
            "archiveSha256": expected_sha256,
        }
    pending["serviceSynced"] = True
    pending["syncedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    state["pendingActivation"] = pending
    _write_state_atomic(args.state_file, state)
    return 0


def _resolve_maintenance_flag(args: argparse.Namespace) -> str:
    explicit = getattr(args, "maintenance_flag", None)
    if explicit:
        return explicit
    return os.path.join(os.path.dirname(os.path.abspath(args.backend_link)), "maintenance.flag")


def _is_maintenance_active(flag_path: str) -> bool:
    return os.path.lexists(flag_path)


def _maintenance_pending_in_state(state: dict[str, Any]) -> bool:
    maint = state.get("maintenance")
    return isinstance(maint, dict) and maint.get("active") is True


def _enable_maintenance(flag_path: str, state_file: str | None, version: str, reason: str) -> None:
    if os.path.isdir(flag_path) and not os.path.islink(flag_path):
        raise ReleaseError(f"Maintenance flag path '{flag_path}' exists and is a directory")
    if os.path.islink(flag_path):
        raise ReleaseError(f"Maintenance flag path '{flag_path}' must not be a symlink")

    parent_dir = os.path.dirname(os.path.abspath(flag_path))
    os.makedirs(parent_dir, exist_ok=True)
    tmp_prefix = ".maintenance-flag-"
    _cleanup_dead_pid_temps(parent_dir, tmp_prefix, is_dir=False)
    fd, tmp_path = tempfile.mkstemp(prefix=f"{tmp_prefix}{os.getpid()}-", dir=parent_dir)
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    payload = {"active": True, "targetVersion": version, "reason": reason, "enteredAt": now_iso}
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, flag_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

    if state_file:
        state = _load_state(state_file)
        state["maintenance"] = payload
        _write_state_atomic(state_file, state)


def _disable_maintenance_flag_only(flag_path: str) -> None:
    if os.path.isdir(flag_path) and not os.path.islink(flag_path):
        raise ReleaseError(f"Maintenance flag path '{flag_path}' is a directory")
    if os.path.lexists(flag_path):
        os.unlink(flag_path)


def is_maintenance_ready(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    flag_path = _resolve_maintenance_flag(args)
    if _is_maintenance_active(flag_path):
        return 0

    current_link = _resolve_current_link(args)
    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        return 1

    state = _load_state(args.state_file)
    if _maintenance_pending_in_state(state):
        return 1

    if getattr(args, "require_service_synced", False) and is_service_synced(args) != 0:
        return 1

    current = state.get("currentKnownGood")
    if not isinstance(current, dict) or current.get("releaseId") != version or current.get("archiveSha256") != expected_sha256:
        return 1

    return 0


def enter_maintenance(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    validate_sha256(args.expected_sha256)
    flag_path = _resolve_maintenance_flag(args)
    _enable_maintenance(flag_path, args.state_file, version, getattr(args, "reason", "release-activation"))
    print(f"Entered controlled NGINX maintenance mode at {flag_path} for release {version}")
    return 0


def _revert_to_known_good(args: argparse.Namespace, failed_version: str) -> str | None:
    maint_flag = getattr(args, "maintenance_flag", None)
    if maint_flag:
        _enable_maintenance(maint_flag, args.state_file, failed_version, f"auto-revert-from-{failed_version}")

    state = _load_state(args.state_file)
    known = state.get("currentKnownGood")
    if not isinstance(known, dict):
        return None
    known_id = known.get("releaseId")
    known_sha = known.get("archiveSha256")
    if not isinstance(known_id, str) or not isinstance(known_sha, str) or known_id == failed_version:
        return None

    ok, _ = is_extracted(args.releases_dir, known_id, known_sha)
    if not ok:
        return None

    current_link = _resolve_current_link(args)
    target_dir = os.path.join(args.releases_dir, known_id)
    b_own = ("root", "root") if args.chown else (None, None)
    f_own = (args.frontend_owner, args.frontend_group) if args.chown else (None, None)
    _ensure_invariant_pair_links(
        args.releases_dir,
        current_link,
        args.backend_link,
        args.frontend_link,
        b_own,
        f_own,
    )
    _atomic_symlink_replace(current_link, target_dir, *b_own)

    state["pendingActivation"] = {
        "releaseId": known_id,
        "archiveSha256": known_sha,
        "serviceSynced": not args.restart_on_revert,
        "revertedFrom": failed_version,
        "revertedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    _write_state_atomic(args.state_file, state)

    if args.restart_on_revert:
        restart_proc = subprocess.run(
            [args.systemctl_bin, "restart", args.backend_service],
            capture_output=True,
            text=True,
            check=False,
        )
        if restart_proc.returncode != 0:
            detail = (restart_proc.stderr or restart_proc.stdout).strip()
            print(
                f"ERROR: Revert backend restart '{args.backend_service}' failed (rc={restart_proc.returncode}): {detail}",
                file=sys.stderr,
            )
            state["pendingActivation"]["serviceSynced"] = False
        else:
            state["pendingActivation"]["serviceSynced"] = True

        nginx_test = subprocess.run([args.nginx_bin, "-t"], capture_output=True, text=True, check=False)
        if nginx_test.returncode == 0:
            reload_proc = subprocess.run(
                [args.systemctl_bin, "reload", args.nginx_service],
                capture_output=True,
                text=True,
                check=False,
            )
            if reload_proc.returncode != 0:
                detail = (reload_proc.stderr or reload_proc.stdout).strip()
                print(
                    f"WARNING: Revert NGINX reload '{args.nginx_service}' failed (rc={reload_proc.returncode}): {detail}",
                    file=sys.stderr,
                )
        else:
            detail = (nginx_test.stderr or nginx_test.stdout).strip()
            print(
                f"WARNING: Revert NGINX configtest failed (rc={nginx_test.returncode}): {detail}",
                file=sys.stderr,
            )
        _write_state_atomic(args.state_file, state)

    return known_id


def verify_health(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    current_link = _resolve_current_link(args)

    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        msg = f"Symlink inconsistency before {args.mode} health check for release {version}"
        print(f"ERROR: {msg}", file=sys.stderr)
        if args.revert_on_fail:
            reverted = _revert_to_known_good(args, version)
            if reverted:
                print(f"Reverted active symlinks cleanly back to known-good release {reverted}", file=sys.stderr)
        return 1

    ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        if args.revert_on_fail:
            reverted = _revert_to_known_good(args, version)
            if reverted:
                print(
                    f"Auto-reverted backend & frontend symlinks back to known-good release '{reverted}' after integrity failure of '{version}'",
                    file=sys.stderr,
                )
        raise ReleaseError(f"Release integrity failure before {args.mode} health check: {reason}")

    cmd = [
        args.python_bin,
        args.health_check_script,
        args.mode,
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--attempts",
        str(args.attempts),
        "--delay",
        str(args.delay),
    ]
    if getattr(args, "expected_release", None):
        cmd += ["--expected-release", args.expected_release]
    if args.mode == "frontend" and args.skip_api_proxy:
        cmd.append("--skip-api-proxy")

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode == 0:
        if proc.stdout:
            print(proc.stdout.strip())
        return 0

    if proc.stderr:
        print(proc.stderr.strip(), file=sys.stderr)
    if args.revert_on_fail:
        reverted = _revert_to_known_good(args, version)
        if reverted:
            print(
                f"Auto-reverted backend & frontend symlinks back to known-good release '{reverted}' after {args.mode} health failure of '{version}'",
                file=sys.stderr,
            )
    return 1


def _list_release_dirs(releases_dir: str) -> list[str]:
    if not os.path.isdir(releases_dir):
        return []
    entries: list[tuple[float, str]] = []
    for name in os.listdir(releases_dir):
        if name.startswith("."):
            continue
        full = os.path.join(releases_dir, name)
        if os.path.isdir(full) and not os.path.islink(full):
            entries.append((os.lstat(full).st_mtime, name))
    entries.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [name for _, name in entries]


def _protected_release_ids(
    releases_dir: str,
    version: str,
    state: dict[str, Any],
    current_link: str,
    backend_link: str,
    frontend_link: str,
) -> set[str]:
    protected = {version}
    for key in ("currentKnownGood", "previousKnownGood"):
        rec = state.get(key)
        if isinstance(rec, dict) and isinstance(rec.get("releaseId"), str):
            rid = rec["releaseId"]
            if os.path.isdir(os.path.join(releases_dir, rid)):
                protected.add(rid)
    for link_path, suffix in (
        (current_link, ""),
        (backend_link, "backend"),
        (frontend_link, os.path.join("frontend", "dist")),
    ):
        active_id = _resolve_active_release_id(releases_dir, link_path, suffix)
        if active_id:
            protected.add(active_id)
    return protected


def _compute_prune_targets(
    releases_dir: str,
    retain_count: int,
    protected_versions: set[str],
) -> list[str]:
    all_releases = _list_release_dirs(releases_dir)
    kept: list[str] = []
    for rel in all_releases:
        if rel in protected_versions and rel not in kept:
            kept.append(rel)
    for rel in all_releases:
        if len(kept) >= retain_count:
            break
        if rel not in kept:
            kept.append(rel)
    kept_set = set(kept)
    return [rel for rel in all_releases if rel not in kept_set]


def _is_promoted_ok(args: argparse.Namespace, version: str, expected_sha256: str) -> bool:
    current_link = _resolve_current_link(args)
    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        return False
    if getattr(args, "require_service_synced", False) and is_service_synced(args) != 0:
        return False
    state = _load_state(args.state_file)
    current = state.get("currentKnownGood")
    if not isinstance(current, dict):
        return False
    return current.get("releaseId") == version and current.get("archiveSha256") == expected_sha256


def is_promoted(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    return 0 if _is_promoted_ok(args, version, expected_sha256) else 1


def promote_release(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    current_link = _resolve_current_link(args)

    ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        raise ReleaseError(f"Cannot promote unverified release '{version}': {reason}")

    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        raise ReleaseError(
            f"Active release pointer '{current_link}' / symlinks do not resolve consistently to '{version}'"
        )

    state = _load_state(args.state_file)
    if getattr(args, "require_service_synced", False) and is_service_synced(args) != 0:
        raise ReleaseError(f"Cannot promote release '{version}' before backend service restart is synced")

    old_current = state.get("currentKnownGood")
    previous = state.get("previousKnownGood")
    if (
        isinstance(old_current, dict)
        and isinstance(old_current.get("releaseId"), str)
        and old_current.get("releaseId") != version
    ):
        previous = old_current
    elif isinstance(previous, dict) and previous.get("releaseId") == version:
        previous = None

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    new_state: dict[str, Any] = dict(state)
    new_state["currentKnownGood"] = {
        "releaseId": version,
        "archiveSha256": expected_sha256,
        "promotedAt": now_iso,
    }
    new_state["previousKnownGood"] = previous
    new_state["pendingActivation"] = {
        "releaseId": version,
        "archiveSha256": expected_sha256,
        "serviceSynced": True,
        "promotedAt": now_iso,
    }
    _write_state_atomic(args.state_file, new_state)
    print(f"Promoted release {version} as currentKnownGood (previous={previous.get('releaseId') if isinstance(previous, dict) else None})")
    return 0


def is_maintenance_clear(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    flag_path = _resolve_maintenance_flag(args)
    if _is_maintenance_active(flag_path):
        return 1
    state = _load_state(args.state_file)
    if _maintenance_pending_in_state(state):
        return 1
    if not _is_promoted_ok(args, version, expected_sha256):
        return 1
    return 0


def exit_maintenance(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    flag_path = _resolve_maintenance_flag(args)
    current_link = _resolve_current_link(args)

    ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        raise ReleaseError(f"Refusing to exit maintenance: unverified release '{version}': {reason}")
    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        raise ReleaseError(f"Refusing to exit maintenance: active symlinks do not match '{version}'")
    if getattr(args, "require_service_synced", False) and is_service_synced(args) != 0:
        raise ReleaseError(f"Refusing to exit maintenance: backend service not synced to '{version}'")

    state = _load_state(args.state_file)
    current = state.get("currentKnownGood")
    if not isinstance(current, dict) or current.get("releaseId") != version or current.get("archiveSha256") != expected_sha256:
        raise ReleaseError(f"Refusing to exit maintenance before release '{version}' is promoted")

    expected_rel = version if getattr(args, "verify_consistency", False) else None
    if getattr(args, "health_check_script", None):
        if getattr(args, "backend_port", None):
            be_cmd = [
                args.python_bin,
                args.health_check_script,
                "backend",
                "--host",
                args.host,
                "--port",
                str(args.backend_port),
                "--attempts",
                str(args.attempts),
                "--delay",
                str(args.delay),
            ]
            if expected_rel:
                be_cmd += ["--expected-release", expected_rel]
            be_proc = subprocess.run(be_cmd, capture_output=True, text=True, check=False)
            if be_proc.returncode != 0:
                print(
                    f"ERROR: Pre-open backend check failed; keeping maintenance active: {(be_proc.stderr or be_proc.stdout).strip()}",
                    file=sys.stderr,
                )
                return 1

        if getattr(args, "verify_port", None):
            fe_cmd = [
                args.python_bin,
                args.health_check_script,
                "frontend",
                "--host",
                args.host,
                "--port",
                str(args.verify_port),
                "--attempts",
                str(args.attempts),
                "--delay",
                str(args.delay),
            ]
            if getattr(args, "skip_api_proxy", False):
                fe_cmd.append("--skip-api-proxy")
            if expected_rel:
                fe_cmd += ["--expected-release", expected_rel]
            fe_proc = subprocess.run(fe_cmd, capture_output=True, text=True, check=False)
            if fe_proc.returncode != 0:
                print(
                    f"ERROR: Pre-open NGINX verification check failed; keeping maintenance active: {(fe_proc.stderr or fe_proc.stdout).strip()}",
                    file=sys.stderr,
                )
                return 1

    _disable_maintenance_flag_only(flag_path)

    if getattr(args, "health_check_script", None) and getattr(args, "listen_port", None):
        pub_cmd = [
            args.python_bin,
            args.health_check_script,
            "frontend",
            "--host",
            args.host,
            "--port",
            str(args.listen_port),
            "--attempts",
            str(args.attempts),
            "--delay",
            str(args.delay),
        ]
        if getattr(args, "skip_api_proxy", False):
            pub_cmd.append("--skip-api-proxy")
        if expected_rel:
            pub_cmd += ["--expected-release", expected_rel]
        pub_proc = subprocess.run(pub_cmd, capture_output=True, text=True, check=False)
        if pub_proc.returncode != 0:
            _enable_maintenance(flag_path, args.state_file, version, f"post-open-check-failed-{version}")
            print(
                f"ERROR: Public port confirmation failed after clearing maintenance; re-armed {flag_path}: {(pub_proc.stderr or pub_proc.stdout).strip()}",
                file=sys.stderr,
            )
            return 1

    state = _load_state(args.state_file)
    state["maintenance"] = {
        "active": False,
        "releaseId": version,
        "clearedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    _write_state_atomic(args.state_file, state)
    print(f"Exited controlled maintenance mode and verified live traffic for release {version}")
    return 0


def is_pruned(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    flag_path = getattr(args, "maintenance_flag", None)
    if flag_path and _is_maintenance_active(flag_path):
        return 1
    state = _load_state(args.state_file)
    if _maintenance_pending_in_state(state):
        return 1
    if not _is_promoted_ok(args, version, expected_sha256):
        return 1
    current_link = _resolve_current_link(args)
    protected = _protected_release_ids(
        args.releases_dir, version, state, current_link, args.backend_link, args.frontend_link
    )
    return 1 if _compute_prune_targets(args.releases_dir, args.retain_releases, protected) else 0


def prune_releases(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    current_link = _resolve_current_link(args)
    if args.retain_releases < 2:
        raise ReleaseError(
            f"retain-releases must be >= 2 so the previous known-good release is always preserved (got {args.retain_releases})"
        )
    flag_path = getattr(args, "maintenance_flag", None)
    if flag_path and _is_maintenance_active(flag_path):
        raise ReleaseError(f"Refusing to prune releases while maintenance flag '{flag_path}' is active")
    state = _load_state(args.state_file)
    if _maintenance_pending_in_state(state):
        raise ReleaseError("Refusing to prune releases while release-state.json reports maintenance active")
    if not _is_promoted_ok(args, version, expected_sha256):
        raise ReleaseError(f"Refusing to prune releases before '{version}' is synced and promoted")

    protected = _protected_release_ids(
        args.releases_dir, version, state, current_link, args.backend_link, args.frontend_link
    )
    prune_list = _compute_prune_targets(args.releases_dir, args.retain_releases, protected)
    for old_rel in prune_list:
        victim = os.path.join(args.releases_dir, old_rel)
        if not os.path.islink(victim) and os.path.isdir(victim):
            shutil.rmtree(victim)
    print(f"Pruned excess releases (protected={sorted(protected)}, pruned={prune_list})")
    return 0


def is_known_good(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    flag_path = getattr(args, "maintenance_flag", None)
    if flag_path and _is_maintenance_active(flag_path):
        return 1
    current_link = _resolve_current_link(args)

    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        return 1

    state = _load_state(args.state_file)
    if _maintenance_pending_in_state(state):
        return 1
    current = state.get("currentKnownGood")
    if not isinstance(current, dict):
        return 1
    if current.get("releaseId") != version or current.get("archiveSha256") != expected_sha256:
        return 1
    if getattr(args, "require_service_synced", False) and is_service_synced(args) != 0:
        return 1

    protected = _protected_release_ids(
        args.releases_dir, version, state, current_link, args.backend_link, args.frontend_link
    )
    to_prune = _compute_prune_targets(args.releases_dir, args.retain_releases, protected)
    return 1 if to_prune else 0


def promote_and_prune(args: argparse.Namespace) -> int:
    version = validate_version(args.version)
    expected_sha256 = validate_sha256(args.expected_sha256)
    current_link = _resolve_current_link(args)
    if args.retain_releases < 2:
        raise ReleaseError(
            f"retain-releases must be >= 2 so the previous known-good release is always preserved (got {args.retain_releases})"
        )
    flag_path = getattr(args, "maintenance_flag", None)
    if flag_path and _is_maintenance_active(flag_path):
        raise ReleaseError(f"Refusing to promote-and-prune while maintenance flag '{flag_path}' is active")

    ok, reason = is_extracted(args.releases_dir, version, expected_sha256)
    if not ok:
        raise ReleaseError(f"Cannot promote unverified release '{version}': {reason}")

    if not _active_pair_matches(args.releases_dir, version, current_link, args.backend_link, args.frontend_link):
        raise ReleaseError(
            f"Active release pointer '{current_link}' / symlinks do not resolve consistently to '{version}'"
        )

    state = _load_state(args.state_file)
    old_current = state.get("currentKnownGood")
    previous = state.get("previousKnownGood")

    if (
        isinstance(old_current, dict)
        and isinstance(old_current.get("releaseId"), str)
        and old_current.get("releaseId") != version
    ):
        previous = old_current
    elif isinstance(previous, dict) and previous.get("releaseId") == version:
        previous = None

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    new_state: dict[str, Any] = {
        "currentKnownGood": {
            "releaseId": version,
            "archiveSha256": expected_sha256,
            "promotedAt": now_iso,
        },
        "previousKnownGood": previous,
        "pendingActivation": {
            "releaseId": version,
            "archiveSha256": expected_sha256,
            "serviceSynced": True,
            "promotedAt": now_iso,
        },
    }

    protected = _protected_release_ids(
        args.releases_dir, version, new_state, current_link, args.backend_link, args.frontend_link
    )
    prune_list = _compute_prune_targets(args.releases_dir, args.retain_releases, protected)

    # Persist promoted known-good state atomically BEFORE deleting any superseded release directories
    # so an interruption during pruning never leaves state pointing to a deleted release.
    _write_state_atomic(args.state_file, new_state)

    for old_rel in prune_list:
        victim = os.path.join(args.releases_dir, old_rel)
        if not os.path.islink(victim) and os.path.isdir(victim):
            shutil.rmtree(victim)

    print(
        f"Promoted release {version} as known-good (protected={sorted(protected)}, pruned={prune_list})"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Puppet Phase 5B release manager")
    sub = parser.add_subparsers(dest="command", required=True)

    p_check = sub.add_parser("is-extracted", help="Check whether verified release is already extracted")
    p_check.add_argument("--version", required=True)
    p_check.add_argument("--expected-sha256", required=True)
    p_check.add_argument("--releases-dir", required=True)

    p_prep = sub.add_parser("prepare", help="Verify checksum/manifest and atomically extract release")
    p_prep.add_argument("--version", required=True)
    p_prep.add_argument("--expected-sha256", required=True)
    p_prep.add_argument("--staging-dir", required=True)
    p_prep.add_argument("--releases-dir", required=True)
    p_prep.add_argument("--backend-owner", default="root")
    p_prep.add_argument("--backend-group", default="gitrepo")
    p_prep.add_argument("--frontend-owner", default="root")
    p_prep.add_argument("--frontend-group", default="www-data")
    p_prep.add_argument("--chown", action="store_true", help="Apply root/service Unix ownership")

    p_iact = sub.add_parser("is-active", help="Check shared release pointer & active symlinks against target version")
    p_iact.add_argument("--version", required=True)
    p_iact.add_argument("--expected-sha256", required=True)
    p_iact.add_argument("--releases-dir", required=True)
    p_iact.add_argument("--current-link", default=None)
    p_iact.add_argument("--backend-link", required=True)
    p_iact.add_argument("--frontend-link", required=True)

    p_act = sub.add_parser("activate", help="Atomically switch shared release pointer for paired backend & frontend")
    p_act.add_argument("--version", required=True)
    p_act.add_argument("--expected-sha256", required=True)
    p_act.add_argument("--releases-dir", required=True)
    p_act.add_argument("--current-link", default=None)
    p_act.add_argument("--backend-link", required=True)
    p_act.add_argument("--frontend-link", required=True)
    p_act.add_argument("--state-file", required=True)
    p_act.add_argument("--frontend-owner", default="root")
    p_act.add_argument("--frontend-group", default="www-data")
    p_act.add_argument("--chown", action="store_true")

    p_iss = sub.add_parser("is-service-synced", help="Check whether backend service restart caught up with active release")
    p_iss.add_argument("--version", required=True)
    p_iss.add_argument("--expected-sha256", required=True)
    p_iss.add_argument("--state-file", required=True)
    p_iss.add_argument("--releases-dir", required=True)
    p_iss.add_argument("--current-link", default=None)
    p_iss.add_argument("--backend-link", required=True)
    p_iss.add_argument("--frontend-link", required=True)

    p_mss = sub.add_parser("mark-service-synced", help="Record that backend service restarted cleanly on active release")
    p_mss.add_argument("--version", required=True)
    p_mss.add_argument("--expected-sha256", required=True)
    p_mss.add_argument("--state-file", required=True)

    p_vh = sub.add_parser("verify-health", help="Run loopback health probe and revert to known-good release on failure")
    p_vh.add_argument("--mode", choices=("backend", "frontend"), required=True)
    p_vh.add_argument("--version", required=True)
    p_vh.add_argument("--expected-sha256", required=True)
    p_vh.add_argument("--state-file", required=True)
    p_vh.add_argument("--releases-dir", required=True)
    p_vh.add_argument("--current-link", default=None)
    p_vh.add_argument("--backend-link", required=True)
    p_vh.add_argument("--frontend-link", required=True)
    p_vh.add_argument("--maintenance-flag", default=None)
    p_vh.add_argument("--expected-release", default=None)
    p_vh.add_argument("--health-check-script", required=True)
    p_vh.add_argument("--python-bin", default="/usr/bin/python3")
    p_vh.add_argument("--host", default="127.0.0.1")
    p_vh.add_argument("--port", type=int, required=True)
    p_vh.add_argument("--attempts", type=int, default=5)
    p_vh.add_argument("--delay", type=float, default=1.0)
    p_vh.add_argument("--skip-api-proxy", action="store_true")
    p_vh.add_argument("--revert-on-fail", action="store_true")
    p_vh.add_argument("--restart-on-revert", action="store_true")
    p_vh.add_argument("--chown", action="store_true")
    p_vh.add_argument("--frontend-owner", default="root")
    p_vh.add_argument("--frontend-group", default="www-data")
    p_vh.add_argument("--systemctl-bin", default="/bin/systemctl")
    p_vh.add_argument("--backend-service", default="git-repo-analyzer-backend")
    p_vh.add_argument("--nginx-bin", default="/usr/sbin/nginx")
    p_vh.add_argument("--nginx-service", default="nginx")

    p_imr = sub.add_parser("is-maintenance-ready", help="Check whether maintenance is active or target release already clean")
    p_imr.add_argument("--version", required=True)
    p_imr.add_argument("--expected-sha256", required=True)
    p_imr.add_argument("--state-file", required=True)
    p_imr.add_argument("--releases-dir", required=True)
    p_imr.add_argument("--current-link", default=None)
    p_imr.add_argument("--backend-link", required=True)
    p_imr.add_argument("--frontend-link", required=True)
    p_imr.add_argument("--maintenance-flag", default=None)
    p_imr.add_argument("--require-service-synced", action="store_true")

    p_em = sub.add_parser("enter-maintenance", help="Enable NGINX 503 maintenance gate prior to switching active release")
    p_em.add_argument("--version", required=True)
    p_em.add_argument("--expected-sha256", required=True)
    p_em.add_argument("--state-file", required=True)
    p_em.add_argument("--backend-link", required=True)
    p_em.add_argument("--maintenance-flag", default=None)
    p_em.add_argument("--reason", default="release-activation")

    p_iprom = sub.add_parser("is-promoted", help="Check if release is active, synced, and recorded as currentKnownGood")
    p_iprom.add_argument("--version", required=True)
    p_iprom.add_argument("--expected-sha256", required=True)
    p_iprom.add_argument("--state-file", required=True)
    p_iprom.add_argument("--releases-dir", required=True)
    p_iprom.add_argument("--current-link", default=None)
    p_iprom.add_argument("--backend-link", required=True)
    p_iprom.add_argument("--frontend-link", required=True)
    p_iprom.add_argument("--require-service-synced", action="store_true")

    p_prom1 = sub.add_parser("promote-release", help="Persist currentKnownGood and previousKnownGood atomically before exiting maintenance")
    p_prom1.add_argument("--version", required=True)
    p_prom1.add_argument("--expected-sha256", required=True)
    p_prom1.add_argument("--state-file", required=True)
    p_prom1.add_argument("--releases-dir", required=True)
    p_prom1.add_argument("--current-link", default=None)
    p_prom1.add_argument("--backend-link", required=True)
    p_prom1.add_argument("--frontend-link", required=True)
    p_prom1.add_argument("--require-service-synced", action="store_true")

    p_imc = sub.add_parser("is-maintenance-clear", help="Check whether maintenance gate is cleared and release promoted")
    p_imc.add_argument("--version", required=True)
    p_imc.add_argument("--expected-sha256", required=True)
    p_imc.add_argument("--state-file", required=True)
    p_imc.add_argument("--releases-dir", required=True)
    p_imc.add_argument("--current-link", default=None)
    p_imc.add_argument("--backend-link", required=True)
    p_imc.add_argument("--frontend-link", required=True)
    p_imc.add_argument("--maintenance-flag", default=None)
    p_imc.add_argument("--require-service-synced", action="store_true")

    p_xm = sub.add_parser("exit-maintenance", help="Verify health & release consistency, remove maintenance flag, and confirm public traffic")
    p_xm.add_argument("--version", required=True)
    p_xm.add_argument("--expected-sha256", required=True)
    p_xm.add_argument("--state-file", required=True)
    p_xm.add_argument("--releases-dir", required=True)
    p_xm.add_argument("--current-link", default=None)
    p_xm.add_argument("--backend-link", required=True)
    p_xm.add_argument("--frontend-link", required=True)
    p_xm.add_argument("--maintenance-flag", default=None)
    p_xm.add_argument("--health-check-script", default=None)
    p_xm.add_argument("--python-bin", default="/usr/bin/python3")
    p_xm.add_argument("--host", default="127.0.0.1")
    p_xm.add_argument("--backend-port", type=int, default=None)
    p_xm.add_argument("--verify-port", type=int, default=None)
    p_xm.add_argument("--listen-port", type=int, default=None)
    p_xm.add_argument("--attempts", type=int, default=5)
    p_xm.add_argument("--delay", type=float, default=1.0)
    p_xm.add_argument("--skip-api-proxy", action="store_true")
    p_xm.add_argument("--verify-consistency", action="store_true")
    p_xm.add_argument("--require-service-synced", action="store_true")

    p_iprn = sub.add_parser("is-pruned", help="Check if release retention pruning has completed outside maintenance")
    p_iprn.add_argument("--version", required=True)
    p_iprn.add_argument("--expected-sha256", required=True)
    p_iprn.add_argument("--state-file", required=True)
    p_iprn.add_argument("--releases-dir", required=True)
    p_iprn.add_argument("--current-link", default=None)
    p_iprn.add_argument("--backend-link", required=True)
    p_iprn.add_argument("--frontend-link", required=True)
    p_iprn.add_argument("--maintenance-flag", default=None)
    p_iprn.add_argument("--retain-releases", type=int, default=3)
    p_iprn.add_argument("--require-service-synced", action="store_true")

    p_prn = sub.add_parser("prune-releases", help="Prune excess old releases after promotion and maintenance exit")
    p_prn.add_argument("--version", required=True)
    p_prn.add_argument("--expected-sha256", required=True)
    p_prn.add_argument("--state-file", required=True)
    p_prn.add_argument("--releases-dir", required=True)
    p_prn.add_argument("--current-link", default=None)
    p_prn.add_argument("--backend-link", required=True)
    p_prn.add_argument("--frontend-link", required=True)
    p_prn.add_argument("--maintenance-flag", default=None)
    p_prn.add_argument("--retain-releases", type=int, default=3)
    p_prn.add_argument("--require-service-synced", action="store_true")

    p_good = sub.add_parser("is-known-good", help="Check if active release matches known-good state, clean maintenance, and retention")
    p_good.add_argument("--version", required=True)
    p_good.add_argument("--expected-sha256", required=True)
    p_good.add_argument("--state-file", required=True)
    p_good.add_argument("--releases-dir", required=True)
    p_good.add_argument("--current-link", default=None)
    p_good.add_argument("--backend-link", required=True)
    p_good.add_argument("--frontend-link", required=True)
    p_good.add_argument("--maintenance-flag", default=None)
    p_good.add_argument("--retain-releases", type=int, default=3)
    p_good.add_argument("--require-service-synced", action="store_true")

    p_prom = sub.add_parser("promote-and-prune", help="Record active release known-good and prune excess older releases")
    p_prom.add_argument("--version", required=True)
    p_prom.add_argument("--expected-sha256", required=True)
    p_prom.add_argument("--state-file", required=True)
    p_prom.add_argument("--releases-dir", required=True)
    p_prom.add_argument("--current-link", default=None)
    p_prom.add_argument("--backend-link", required=True)
    p_prom.add_argument("--frontend-link", required=True)
    p_prom.add_argument("--maintenance-flag", default=None)
    p_prom.add_argument("--retain-releases", type=int, default=3)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "is-extracted":
            ok, msg = is_extracted(
                args.releases_dir,
                validate_version(args.version),
                validate_sha256(args.expected_sha256),
            )
            if not ok:
                print(msg, file=sys.stderr)
                return 1
            return 0
        if args.command == "prepare":
            return prepare_release(args)
        if args.command == "is-active":
            return is_active(args)
        if args.command == "activate":
            return activate_release(args)
        if args.command == "is-service-synced":
            return is_service_synced(args)
        if args.command == "mark-service-synced":
            return mark_service_synced(args)
        if args.command == "verify-health":
            return verify_health(args)
        if args.command == "is-maintenance-ready":
            return is_maintenance_ready(args)
        if args.command == "enter-maintenance":
            return enter_maintenance(args)
        if args.command == "is-promoted":
            return is_promoted(args)
        if args.command == "promote-release":
            return promote_release(args)
        if args.command == "is-maintenance-clear":
            return is_maintenance_clear(args)
        if args.command == "exit-maintenance":
            return exit_maintenance(args)
        if args.command == "is-pruned":
            return is_pruned(args)
        if args.command == "prune-releases":
            return prune_releases(args)
        if args.command == "is-known-good":
            return is_known_good(args)
        if args.command == "promote-and-prune":
            return promote_and_prune(args)
        raise ReleaseError(f"Unsupported command: {args.command}")
    except ReleaseError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
