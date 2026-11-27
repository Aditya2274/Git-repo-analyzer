# Automated Application Release Packaging Guide

This document describes the automated application release-packaging mechanism for the **Git Repository Analyzer** platform, implemented in [`scripts/package_release.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/package_release.sh).

---

## 1. Objective and Architecture Context

The release packager creates self-contained, reproducible, secure production release bundles containing both the React frontend production assets and the Node.js / Express backend runtime with isolated production dependencies.

The generated bundles are designed for direct ingestion and verification by Puppet's application release management subsystem on the Application & Monitoring Server (`app-server` / EC2 2), implemented in [`puppet/modules/application/files/release_manager.py`](file:///home/aditya-2274/Git-repo-analyzer/puppet/modules/application/files/release_manager.py).

---

## 2. Prerequisites and Environment Validation

Before executing builds or packaging, [`scripts/package_release.sh`](file:///home/aditya-2274/Git-repo-analyzer/scripts/package_release.sh) enforces fail-closed checks on the host environment:

| Requirement                 | Specification                                                                                                      | Enforcement Policy                                  |
| :-------------------------- | :----------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------- |
| **Node.js**           | Node.js 24 LTS (`^v?24(\.\|$)`)                                                                                   | Strict. Aborts if Node is missing or version != 24. |
| **npm**               | Standard Node Package Manager                                                                                      | Verifies availability in `PATH`.                  |
| **System Utilities**  | `tar` (POSIX/GNU), `sha256sum`, `git`                                                                        | Verifies availability in `PATH`.                  |
| **Project Manifests** | `backend/package.json`, `backend/package-lock.json`, `frontend/package.json`, `frontend/package-lock.json` | Verifies existence before executing compilation.    |

The script **never** installs or upgrades system packages or mutates the developer's local workspace manifests.

---

## 3. CLI Interface and Usage

### Syntax

```bash
# Basic usage
scripts/package_release.sh <VERSION>

# Named options
scripts/package_release.sh -v <VERSION> [-o <OUTPUT_DIR>] [--skip-build]
scripts/package_release.sh --version <VERSION> [--output-dir <OUTPUT_DIR>] [--skip-build]

# Help
scripts/package_release.sh --help
```

### Options

- `-v, --version <VERSION>`: Release version identifier (e.g., `1.0.0`, `1.2.0-rc1`). Must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` and cannot contain path traversal sequences (`..`).
- `-o, --output-dir <DIR>`: Output directory for release bundles and checksums (default: `<PROJECT_ROOT>/dist-release`).
- `-s, --skip-build`: Skip re-running `npm run build` if fresh production builds already exist in `backend/dist` and `frontend/dist`.
- `-h, --help`: Display usage summary and exit.

---

## 4. Packaging Pipeline Workflow

```text
 ┌──────────────────────┐
 │ Validate Environment │ (Node.js 24, npm, git, tar, sha256sum, manifests)
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │   Production Build   │ Backend:  tsc -p tsconfig.build.json
 │                      │ Frontend: tsc --noEmit && vite build
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ Staging Tree Assembly│ In isolated temporary directory (mktemp -d):
 │    & Dependency      │ • Copy backend/dist, package.json, package-lock.json
 │      Isolation       │ • Run 'npm ci --omit=dev --ignore-scripts'
 │                      │ • Copy frontend/dist
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │   Generate Manifest  │ Write release-manifest.json:
 │                      │ • releaseId, gitCommit, builtAtUtc, nodeVersion
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │   Security Audit     │ Fail-closed checks:
 │   on Staging Tree    │ • Verify required files exist
 │                      │ • Reject .env*, .git*, backend/src, backend/test
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ Create Dual Archives │ • Primary: git-repo-analyzer-release-<VERSION>.tar.gz
 │     & Sidecars       │ • Compat:  <VERSION>.tar.gz (hardlink, regular file)
 │                      │ • Checksums: <archive>.sha256 (sha256sum -c --strict)
 └──────────────────────┘
```

---

## 5. Archive Structure and Member Constraints

The generated `.tar.gz` archive enforces member isolation conforming to `release_manager.py`:

```text
<archive-root>/
├── release-manifest.json        (644 root:root metadata manifest)
├── backend/
│   ├── dist/
│   │   └── server.js            (Compiled Express application)
│   ├── package.json             (Application manifest)
│   ├── package-lock.json        (Lockfile)
│   └── node_modules/            (Production-only dependencies: express, cors, zod)
└── frontend/
    └── dist/
        ├── index.html           (Production Single Page Application entry)
        └── assets/
            ├── index-*.css      (Compiled Tailwind styling)
            └── index-*.js       (Compiled React/Recharts bundle)
```

### Prohibited Artifacts (Strictly Excluded)

- `backend/.env*` and root `.env*` (secrets must be injected exclusively at runtime by Puppet from `/etc/git-repo-analyzer/backend.env`).
- `.git/` directories and repository metadata.
- `backend/src/` and `frontend/src/` (TypeScript source files).
- `backend/test/` and `frontend/test/` (unit and integration test suites).
- Development dependencies (`typescript`, `@types/*`, `vitest`, `eslint`).
- Symlinks outside or escaping `backend/` sandbox.

---

## 6. Manifest Specification (`release-manifest.json`)

The archive root contains `release-manifest.json` structured as follows:

```json
{
  "appName": "git-repo-analyzer",
  "releaseId": "1.0.0",
  "gitCommit": "f6b25ddf73f3a2d870d8ceb62ac96cea343ef41d",
  "builtAtUtc": "2026-11-27T10:48:00Z",
  "nodeVersion": "v24.13.1"
}
```

> [!IMPORTANT]
> The `release-manifest.json` file **must not** contain an `archiveSha256` key. In accordance with `release_manager.py` line 533, self-referential checksum keys inside the archive are forbidden; checksum verification is conducted strictly via external `.sha256` sidecar files.

---

## 7. Dual Naming and Staging Compatibility

To support both human-readable naming conventions and Puppet's strict naming expectations:

1. **Primary Archive**: `git-repo-analyzer-release-<VERSION>.tar.gz`
   - Accompanied by `git-repo-analyzer-release-<VERSION>.tar.gz.sha256`
2. **Puppet Staging Archive**: `<VERSION>.tar.gz`
   - Accompanied by `<VERSION>.tar.gz.sha256`
   - Created via a hard link (`ln -f`) to ensure both files share the exact same inode.
   - Neither file is a symbolic link (`test ! -L`), satisfying `release_manager.py`'s strict prohibition on symlinks within the staging directory (`os.path.islink(path)` must return `False`).

Both sidecar files follow the canonical GNU coreutils format:

```text
<64-hex-sha256>  <archive-filename>
```

and validate strictly with `sha256sum -c --strict <sidecar>`.

---

## 8. Verification and Test Suite

A dedicated test suite is provided in [`cicd/tests/test_package_release.sh`](file:///home/aditya-2274/Git-repo-analyzer/cicd/tests/test_package_release.sh).

To run the test suite:

```bash
cicd/tests/test_package_release.sh
```

The suite validates:

1. Script existence and executable permissions.
2. Argument handling and input sanitization (path traversal, metacharacters, format errors).
3. Fail-closed Node.js 24 runtime enforcement.
4. End-to-end package generation with real production builds.
5. Dual archive creation, regular file status, and hardlink inode sharing.
6. SHA-256 sidecar format and `sha256sum -c --strict` verification.
7. Tar member hierarchy and isolation (production modules present, devDependencies and prohibited files absent).
8. `release-manifest.json` schema compliance.
9. End-to-end verification and extraction using Puppet's live [`release_manager.py`](file:///home/aditya-2274/Git-repo-analyzer/puppet/modules/application/files/release_manager.py).
10. Fast repackaging with `--skip-build`.
