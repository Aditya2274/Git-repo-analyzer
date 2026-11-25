# Phase 5B Handover Contract: Application Configuration & Deployment (EC2 2)

- **Source Milestone:** Phase 6 — Checkpoint 6.4 (Integrated Build Verification & Phase 5B Handover)
- **Target Node:** `app-server` (EC2 2 — `t3.micro`, Ubuntu 24.04 LTS)
- **Desired-State Owner:** Puppet (`application` / `nginx` manifests in Phase 5B) per ADR 006
- **Authorization Scope:** Local contract specification prepared under Approval Boundary A; live AWS execution awaits Boundary B

---

## 1. Purpose and Handover Boundary

Phase 6 verified the backend (`backend/`) and frontend (`frontend/`) builds, tests, API contracts, disk persistence, and mocked end-to-end execution locally. Phase 5B translates those verified contracts into Puppet manifests on **EC2 2 (`app-server`)** without modifying:

- The 3-EC2 architecture (`puppet-server`, `app-server`, `cicd-server`).
- Phase 4 Ansible bootstrap roles (`common`, `docker`, `nginx`, `puppet_server`, `puppet_agent`).
- Phase 5A Puppet modules (`common`, `nrpe`, `nagios`) or Terraform S3/SG configuration.
- Frozen analyzer files (`analyze2.sh`, `ai/*`, `Dockerfile`, `Jenkinsfile`).

Once Puppet manages NGINX, Node.js 24 LTS, systemd unit, and backend environment files on `app-server`, Ansible must never re-run NGINX virtual host or service management tasks against EC2 2 (ADR 006).

---

## 2. Application Directory, Ownership & Permission Contract

| Path | Owner : Group | Mode | Purpose & Contents | Source / Managed By |
| :--- | :--- | :---: | :--- | :--- |
| `/var/cache/git-repo-analyzer` | `root:root` | `0755` | Release staging parent directory | Puppet (`file`) |
| `/var/cache/git-repo-analyzer/staging` | `ubuntu:ubuntu` | `0750` | Temporary landing directory for transferred release archive (`git-repo-analyzer-release-<id>.tar.gz`) and external checksum sidecar (`.tar.gz.sha256`) | Populated (`ubuntu` writable) via SSH under Boundary B; read/verified by Puppet (`root`), unreadable by `gitrepo`/`www-data` |
| `/opt/git-repo-analyzer` | `root:root` | `0755` | Application release root directory (`gitrepo` and `www-data` traverse) | Puppet (`file`) |
| `/opt/git-repo-analyzer/releases` | `root:root` | `0755` | Parent directory holding immutable extracted versioned releases (active + retained previous known-good release) | Puppet (`file`) |
| `/opt/git-repo-analyzer/releases/<release-id>` | `root:root` | `0755` | Extracted immutable versioned release root (`release-manifest.json`, `backend/`, `frontend/`, `.extracted.ok`) | Verified & extracted exclusively by Puppet; non-writable by runtime services |
| `/opt/git-repo-analyzer/releases/<release-id>/backend` | `root:gitrepo` | `0750` dirs / `0640` files (`0750` scripts if executable) | Extracted backend runtime subtree (`dist/server.js`, `package.json`, `package-lock.json`, `node_modules/`); readable/executable by `gitrepo`, writable only by `root` | Puppet (`application::release`) |
| `/opt/git-repo-analyzer/releases/<release-id>/frontend/dist` | `root:www-data` | `0750` dirs / `0640` files | Extracted frontend static SPA subtree (`index.html`, `assets/*`); traversable/readable by NGINX (`www-data`), writable only by `root` | Puppet (`application::release`) |
| `/opt/git-repo-analyzer/current` | `root:root` (symlink `0777`) | symlink | Single shared atomic release pointer $\rightarrow$ `/opt/git-repo-analyzer/releases/<release-id>` (switched via one atomic `os.replace()` syscall) | Managed & switched exclusively by Puppet (`release_manager.py`) |
| `/opt/git-repo-analyzer/backend` | `root:root` (symlink `0777`) | symlink | Invariant backend symlink $\rightarrow$ `/opt/git-repo-analyzer/current/backend` (resolves via `current` into `root:gitrepo` `0750`/`0640`) | Managed exclusively by Puppet |
| `/var/www/git-repo-analyzer` | `root:www-data` | `0750` | Web root parent directory (NGINX `www-data` traversal) | Puppet (`file`) |
| `/var/www/git-repo-analyzer/dist` | `root:www-data` (symlink `0777`) | symlink | Invariant frontend symlink $\rightarrow$ `/opt/git-repo-analyzer/current/frontend/dist` (resolves via `current` into `root:www-data` `0750`/`0640`) | Managed exclusively by Puppet |
| `/var/lib/git-repo-analyzer` | `root:gitrepo` | `0750` | Persistent runtime state parent directory (`gitrepo` traversal) | Puppet (`file`) |
| `/var/lib/git-repo-analyzer/data` | `gitrepo:gitrepo` | `0750` | Persistent mutable state (`analyses.json`) & cached non-executable PNG charts (`artifacts/<id>/`) | External to `releases/`; writable by `gitrepo` (`DATA_DIR`) |
| `/etc/git-repo-analyzer` | `root:gitrepo` | `0750` | Restricted environment directory | Puppet (`file`) |
| `/etc/git-repo-analyzer/backend.env` | `root:gitrepo` | `0640` | Runtime environment variables & Phase 7 secrets (root read/write, `gitrepo` read-only) | Puppet (`file` / Hiera) |
| `/etc/systemd/system/git-repo-analyzer-backend.service` | `root:root` | `0644` | Backend systemd service definition | Puppet (`file`) |

**Execution Identity & Non-Writable Release Contract:**
- System group: `gitrepo` (`ensure => present`, `system => true`).
- System user: `gitrepo` (`ensure => present`, `system => true`, `gid => 'gitrepo'`, `home => '/nonexistent'`, `managehome => false`, `shell => '/usr/sbin/nologin'`).
- NGINX runtime identity: `www-data` (Ubuntu distribution default).
- **Least-Privilege Write Separation:** Runtime services (`gitrepo` and `www-data`) run with read/traverse/execute access to their respective release subtrees (`root:gitrepo` `0750`/`0640` for backend; `root:www-data` `0750`/`0640` for frontend) while **zero** files inside `/opt/git-repo-analyzer/releases/` are writable by `gitrepo` or `www-data`. Only `/var/lib/git-repo-analyzer/data` is writable by `gitrepo` (`0750`) for analysis persistence.

> [!NOTE]
> Setting `DATA_DIR=/var/lib/git-repo-analyzer/data` explicitly separates mutable analysis persistence (`analyses.json` + cached PNG artifacts) from immutable release code under `/opt/git-repo-analyzer/backend`. If `DATA_DIR` is omitted, `backend/dist/config/env.js` defaults to `${WorkingDirectory}/data`.

---

## 3. Backend Runtime & Installation Requirements

- **Target Runtime:** **Node.js 24 LTS** (replacing EOL Node.js 20 LTS, which reached end-of-life on April 30, 2026).
- **Ubuntu 24.04 LTS Installation Approach (Deferred to Phase 5B):**
  - Ubuntu 24.04 default APT repositories package Node.js 18.x and must not be used.
  - Phase 5B Puppet manifests will configure the official **NodeSource Node.js 24.x** APT repository (`https://deb.nodesource.com/node_24.x`, suite `nodistro`, component `main`, signed with `https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key` / keyring `nodesource.gpg`) and install the `nodejs` Debian/Ubuntu package.
  - Live `nodejs` package installation via APT on EC2 2 has **not** been executed in Checkpoint 6.4 and remains deferred to **Phase 5B** under live/target host provisioning.
- **Systemd Executable Path:** `/usr/bin/node /opt/git-repo-analyzer/backend/dist/server.js` binding strictly to `127.0.0.1:3000` (standard package path installed by the Ubuntu NodeSource `nodejs` package; local development tests use nvm's Node `v24.13.1`, not system `/usr/bin/node`).
- **Local Compatibility Verification (Node `v24.13.1` / npm `11.8.0`):**
  - **Dependencies:** Inspected all `engines.node` fields across `backend/package-lock.json` (`57` entries) and `frontend/package-lock.json` (`249` entries); zero dependencies impose a `<24` or `^20` upper ceiling.
  - **Runtime & Build Tests:** Executed `npm ci && npm run typecheck && npm run build && npm test` on `backend` (`21/21` passing, compiled runtime dependencies strictly `express`, `cors`, `zod`, and Node built-ins `node:dns`, `node:http`, `node:https`, `node:net`, `node:crypto`, `node:fs/promises`, `node:path`) and `frontend` (`5` files, `14/14` passing) under Node `v24.13.1`.
- **Production Dependencies Only:** `backend/package.json` runtime dependencies are strictly `express`, `cors`, and `zod`. Development packages (`typescript`, `@types/*`) and test suites are **not** required at runtime (`npm ci --omit=dev`).
- **Pre-Built Deployment Constraint (`t3.micro` 1 GB RAM):** Build `backend/dist/` and `frontend/dist/` outside EC2 2 (CI/build host) rather than invoking `tsc` or `vite build` on the `t3.micro` host.
- **Process Cardinality Constraint:** Because `FileAnalysisStore` serializes atomic writes in-process (`analyses.json` + `.analyses.json.tmp.*`), the backend must run as a **single Node.js process** (no Node cluster mode or multi-replica instances per ADR 001/009).

---

## 4. Frontend Static Deployment Requirements

- Build static assets cleanly via `cd frontend && npm run build` with `VITE_API_BASE_URL` **unset/empty** (matching `frontend/.env.example`).
- Deploy `frontend/dist/` (`index.html`, `assets/*.js`, `assets/*.css`) to `/var/www/git-repo-analyzer/dist`.
- **Relative API Routing:** The compiled frontend defaults all requests to `/api/...` (`/api/health`, `/api/analyses`, `/api/analyses/:id`, `/api/analyses/:id/results`, `/api/analyses/:id/charts/:name`) so zero IPs, hostnames, Jenkins URLs, or credentials exist inside static JS bundles.
- **Prohibition:** Never run the Vite development server (`npm run dev` / port `5173`) in EC2 production.

---

## 5. Runtime Environment Variables & Classification

Verified against [`backend/src/config/env.ts`](file:///home/aditya-2274/Git-repo-analyzer/backend/src/config/env.ts):

### 5.1 Required / Core Variables

| Variable | Phase 5B Value (Mock Mode) | Phase 7 Value (Live Jenkins) | Classification | Source / Security Constraint |
| :--- | :--- | :--- | :--- | :--- |
| `PORT` | `3000` | `3000` | 1. Static app config | Loopback HTTP listen port matching NGINX proxy & contracts |
| `NODE_ENV` | `production` | `production` | 1. Static app config | Enforces fail-closed `SSRF_CHECK_DNS` guard & sanitized 500 errors |
| `DATA_DIR` | `/var/lib/git-repo-analyzer/data` | `/var/lib/git-repo-analyzer/data` | 1. Static app config | Writable directory owned `gitrepo:gitrepo` (`0750`) |
| `CORS_ORIGIN` | `http://<app_server_public_ip>` | `http://<app_server_public_ip>` | 2. Terraform output derived | Populated post-`terraform apply` from `app_server_public_ip` (plus `app_server_public_dns` if accessed by DNS) |
| `JENKINS_MOCK_MODE` | `true` | `false` | 1 / 3. Phase-gated toggle | Starts `true` in Phase 5B; flips to `false` only in Phase 7 after Jenkins controller setup |
| `JENKINS_URL` | *(empty)* | `http://<cicd_server_private_ip>:8080` | 2 + 3. Terraform private IP + Jenkins port | Private network address only (`cicd_server_private_ip` or `http://cicd-server:8080` from `/etc/hosts`); optional when mockMode=`true` |
| `JENKINS_USER` | *(empty)* | `backend-service` | 3. Jenkins configuration | Non-admin Jenkins service account created in Phase 7 |
| `JENKINS_API_TOKEN` | *(empty)* | `<operator-provisioned-secret>` | 4. Secret requiring secure provisioning | Required when `JENKINS_MOCK_MODE=false`; supplied outside Git/Terraform outputs/ordinary inventory (`backend.env` `0640`) |
| `JENKINS_JOB_NAME` | `git-repo-analyzer` | `git-repo-analyzer` | 3. Jenkins configuration | Parameterized pipeline job accepting `REPO_URL` |

### 5.2 Additional Supported Backend Variables (`backend/src/config/env.ts`)

| Variable | Default / Production Value | Classification | Notes |
| :--- | :--- | :--- | :--- |
| `HOST` | `127.0.0.1` | 1. Static app config | Keeps Node listener strictly loopback-bound behind NGINX |
| `SSRF_CHECK_DNS` | `true` | 1. Static app config | Startup fails closed (`exit 1`) if set `false` while `NODE_ENV=production` |
| `ANALYSIS_TIMEOUT_MS` | `600000` | 1. Static app config | 10-minute upper bound before interrupted/stalled jobs fail cleanly |
| `POLL_INTERVAL_MS` | `1500` | 1. Static app config | Server-side Jenkins poll interval (ms) |
| `JENKINS_REQUEST_TIMEOUT_MS` | `5000` | 1. Static app config | Per-request timeout for Jenkins HTTP calls (ms) |

> [!IMPORTANT]
> **Critical Phase 5B `CORS_ORIGIN` Finding & Fail-Closed Enforcement:** Because Chromium/Firefox send an `Origin: http://<app_server_public_ip>` header on same-origin `POST /api/analyses` requests even behind an NGINX reverse proxy, leaving `CORS_ORIGIN=` blank in `NODE_ENV=production` causes Express to reject `POST /api/analyses` with **`403 CORS_FORBIDDEN`** (empirically verified in Checkpoint 6.4 and live NGINX $\leftrightarrow$ Express tests in Phase 5B). `application::backend` enforces `enforce_production_cors => true` by default whenever `release_active => true` and `NODE_ENV=production`, failing catalog compilation unless single or comma-separated `http(s)://host[:port]` origins (`application::cors_origin`) with valid ports (`1`–`65535`) and no stray commas are populated from Terraform outputs (`app_server_public_ip` / `app_server_public_dns`), and normalizes whitespace around commas in `backend.env`. Wildcards (`*`), embedded credentials, paths, and explicit empty `Origin: ""` headers are rejected; backend CORS never enables `Access-Control-Allow-Credentials`.

---

## 6. Systemd Service Contract (`/etc/systemd/system/git-repo-analyzer-backend.service`)

```ini
[Unit]
Description=AI-Powered Git Repository Analyzer Express Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=gitrepo
Group=gitrepo
WorkingDirectory=/opt/git-repo-analyzer/backend
EnvironmentFile=/etc/git-repo-analyzer/backend.env
ExecStart=/usr/bin/node /opt/git-repo-analyzer/backend/dist/server.js
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Puppet must execute `systemctl daemon-reload` on unit change and enforce `ensure => running, enable => true` (notifying restart on unit or `backend.env` changes).

---

## 7. NGINX Reverse-Proxy Contract (EC2 2)

In Phase 4.7, Ansible `roles/nginx/` deployed a baseline `/etc/nginx/sites-available/default` (`default_server` on port `80` serving `/var/www/html` and `/healthz`) and removed `sites-enabled/git-repo-analyzer`.

In Phase 5B, Puppet's NGINX configuration assumes exclusive ownership:
1. Disable/replace `/etc/nginx/sites-enabled/default` so zero conflicting `default_server` blocks exist on port `80`.
2. Deploy production vhost (port `80`, `server_name _;`, `server_tokens off;`, `autoindex off;`):
   - `root /var/www/git-repo-analyzer/dist;`
   - `location /` and `location /assets/`: static SPA (`try_files $uri $uri/ /index.html`), cache headers on `/assets/`, and static security headers (`X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy`) applied on static locations without overriding Express `X-Frame-Options: DENY` / `Referrer-Policy: no-referrer` on `/api/`.
   - `location /api/ { proxy_pass http://127.0.0.1:3000/api/; ... }` preserving `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`, and passing `Origin` transparently (`CORS_ORIGIN` enforces allowlisting cleanly).
   - Keep `location = /healthz { return 200 "ok\n"; }` (preserving baseline synthetic NGINX check cleanly alongside `/api/health`).
   - Implement a controlled Puppet-managed maintenance gate on the public `listen_port` using `/opt/git-repo-analyzer/maintenance.flag` (`server`-level `if (-f ...)` $\rightarrow$ internal `return 598` $\rightarrow$ `error_page 598 =503 @app_maintenance_page` returning HTTP `503`, `Retry-After: 5`, `Cache-Control: no-store`, and `{"status":"MAINTENANCE"}` across `/`, `/assets/`, and `/api/` without masking Express's own `503` when maintenance is inactive, while leaving `/healthz` at `200`). Zero downtime is explicitly **not** claimed: on single `t3.micro` (`FileAnalysisStore`), briefly returning `503 MAINTENANCE` prevents clients from receiving mismatched new frontend assets with an old pre-restart backend process.
   - Bind an internal loopback verification server (`listen 127.0.0.1:8081;` by default via `application::nginx_verify_port`, guarded against colliding with `listen_port`, `backend_port`, or Nagios Apache `127.0.0.1:8080`) with identical `root` and `/api/` proxy so Puppet can verify real NGINX frontend + API parity while public traffic stays gated in `503` maintenance.
   - Do **not** proxy `/nagios` through NGINX (Apache Nagios UI remains strictly on loopback `127.0.0.1:8080` per ADR/AGENTS.md).
3. Validate full configuration syntax (`nginx -t` via refresh `app_nginx_configtest` and pre-start `app_nginx_configtest_before_start` gates) before notifying or starting `Service['nginx']`.

---

## 8. Health Check Contract

- **Backend endpoint:** `GET http://127.0.0.1:3000/api/health`
- **Loopback NGINX verification endpoint:** `GET http://127.0.0.1:8081/` and proxied `GET http://127.0.0.1:8081/api/health` (bypasses public maintenance flag during activation)
- **Public proxied endpoint (via NGINX):** `GET http://<app_server_public_ip>/api/health`
- **Expected response when store ready (packaged release):** HTTP `200` `{"status":"UP","timestamp":"<ISO-8601>","releaseId":"<version>"}` plus response header `X-App-Release: <version>` (resolved once at Node process startup from immutable `release-manifest.json`; omitted in standalone unit tests without release wrapper).
- **Frontend runtime identity:** `<meta name="app-release-id" content="<version>" />` embedded and validated in `frontend/dist/index.html`; `health_check.py --expected-release <version>` enforces that NGINX `GET /` HTML and running backend `GET /api/health` both report the exact same target `<version>` (with `X-App-Release` header and JSON `releaseId` agreeing) before opening public traffic.
- **Controlled maintenance response (during rollout/failure):** HTTP `503` `{"status":"MAINTENANCE",...}` with `Retry-After: 5`.
- **Failure response if `FileAnalysisStore` uninitialized:** HTTP `503` `{"error":{"code":"SERVICE_UNAVAILABLE",...}}` (never masked by NGINX `@app_maintenance_page`).
- **Monitoring dependency:** Phase 5A Nagios currently monitors `NGINX Web Server Port 80` (`check_http_port!80`); explicit active Nagios monitoring of `/api/health` / backend process will be completed in **Phase 8** after Phase 5B deploys the backend.

---

## 9. Release Artifact Staging & Deployment Strategy

### 9.1 Architectural Constraints

- **Three-EC2 Topology Preserved:** EC2 1 (`puppet-server`), EC2 2 (`app-server`, `t3.micro` 1 GB RAM / 15 GB gp3), EC2 3 (`cicd-server`). No extra server, IAM role, S3 application bucket, or deployment SaaS service is added.
- **No Build Toolchain on EC2 2:** Zero TypeScript (`tsc`), Vite (`vite build`), or dev-dependency installation on `t3.micro` (`t3.micro` runs only `/usr/bin/node` + pre-built artifacts; observed pre-build sizes: `backend/dist` ~`268 KB`, `frontend/dist` ~`764 KB`, runtime-only `express`/`cors`/`zod` packages contain zero native `.node` addons).
- **Puppet Ownership Preserved (ADR 006):** Puppet must not transfer large release archives via Puppet master catalogs/fileserver, and Ansible must never overwrite Puppet-managed runtime directories, permissions, symlinks, NGINX virtual hosts, or systemd services.

### 9.2 Evaluation of Candidate Approaches

| Strategy | Complexity | Reproducibility & Integrity | Auth & Secrets | Arch & Puppet Compatibility | Rollback | Added AWS Cost / Infra | Verdict |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Direct Ansible file/dir copy** (copying raw trees without versioned archive/manifest) | Low | Low–Moderate (mutable in-place tree; no checksum gate) | Reuses existing SSH trust | Risk of Ansible-vs-Puppet ownership conflict unless wrapped carefully | Weak (in-place overwrite) | None (`$0`) | **Insufficient alone** |
| **2. Pre-built immutable versioned tarball staged via SSH/SCP or authorized Ansible deploy helper, extracted/activated by Puppet** | **Low** | **High** (`npm ci --omit=dev` + `vite build`, `release-manifest.json`, `.sha256` gate) | **Strong** (reuses `~/.ssh/git-repo-analyzer.pem`, `ansible/known_hosts`, operator `/32` SSH SG; zero cloud keys needed) | **High** (staging writes solely to drop-zone; Puppet owns extraction, permissions, symlinks, services) | **Strong** (retain prior `releases/<id>/`, switch active release symlink) | **None (`$0`)** | **CHOSEN** |
| **3. Transfer archive from EC2 3 (Jenkins)** | Moderate | Moderate–High | Requires cross-instance SSH/HTTP creds | **Incompatible** (Terraform SGs block EC2 3 $\rightarrow$ EC2 2 port 22; Phase 5B runs *before* Phase 7 Jenkins install) | Moderate | None | **Rejected** |
| **4. S3 bucket storage + EC2 pull** | High | High | Requires new IAM instance profile + bucket policy | **Incompatible** (`terraform/modules/ec2/main.tf` defines no IAM profile; S3 state bucket is reserved strictly for Terraform state) | High | Extra S3 storage/requests + Terraform changes | **Rejected** |

### 9.3 Chosen Strategy & Separation of Ownership *(Designed; Not Yet Implemented/Tested)*

- **Chosen Pattern:** **Versioned Immutable Release Archive (`git-repo-analyzer-release-<release-id>.tar.gz`) + External Checksum Sidecar (`git-repo-analyzer-release-<release-id>.tar.gz.sha256`), built on the operator build workstation, transferred under explicit Boundary B authorization into EC2 2's staging drop-zone via existing SSH trust (`ansible/ssh.cfg` + `ansible/known_hosts`), and verified/extracted/activated exclusively by Puppet.**
- **Ownership Boundary:**
  1. **Operator Build Workstation (Local):** Builds `backend/dist/`, installs backend production-only dependencies (`npm ci --omit=dev`), builds `frontend/dist/`, generates `release-manifest.json` (metadata only — no archive checksum inside), archives the immutable `.tar.gz`, and **after archive creation** calculates the external `.tar.gz.sha256` sidecar file.
  2. **Stage Transfer (Authorized Boundary B Step Only):** Transfers solely the `.tar.gz` archive and `.tar.gz.sha256` sidecar into `/var/cache/git-repo-analyzer/staging/` using existing SSH key (`~/.ssh/git-repo-analyzer.pem`, `0400`) restricted to `var.allowed_ssh_cidr` (`ubuntu` user). Does not touch `/opt/git-repo-analyzer/`, `/var/www/git-repo-analyzer/`, `/etc/git-repo-analyzer/`, or systemd/NGINX.
  3. **Puppet Activation (Phase 5B `application::release`):** If `/opt/git-repo-analyzer/releases/<release-id>/.extracted.ok` is not already present, verifies the external `.sha256` sidecar against expected Hiera `application::release::expected_sha256` AND verifies archive integrity via `sha256sum -c` **before** `tar` extraction, unpacks idempotently into `/opt/git-repo-analyzer/releases/<release-id>/`, enforces `root:gitrepo` / `root:www-data` non-writable release permissions, updates active symlinks (`/opt/git-repo-analyzer/backend` and `/var/www/git-repo-analyzer/dist`), leaves `/var/lib/git-repo-analyzer/data` untouched, and notifies `Service['git-repo-analyzer-backend']` + `Service['nginx']`.
  4. **Post-Health Cleanup Gate:** Retention pruning removes old extracted releases (`> 2` retained) **only after** post-activation health validation passes (`http://127.0.0.1:3000/api/health` returns `200 UP` and NGINX returns `200`), and never deletes either the currently active release or the immediately preceding known-good release.

### 9.4 Release Archive Layout & Manifest Contract

**Staged Artifacts on EC2 2 (`/var/cache/git-repo-analyzer/staging/`):**
- `git-repo-analyzer-release-<releaseId>.tar.gz` — Immutable compressed archive containing only:
  ```text
  release/
  ├── release-manifest.json    # Build provenance only (NO archiveSha256 field inside)
  ├── backend/
  │   ├── dist/
  │   ├── package.json
  │   ├── package-lock.json
  │   └── node_modules/        # populated strictly via `npm ci --omit=dev`
  └── frontend/
      └── dist/                # populated strictly via `vite build` (`VITE_API_BASE_URL` unset)
  ```
- `git-repo-analyzer-release-<releaseId>.tar.gz.sha256` — External checksum sidecar file generated **after** archive creation (`sha256sum git-repo-analyzer-release-<releaseId>.tar.gz > git-repo-analyzer-release-<releaseId>.tar.gz.sha256`), avoiding circular hash self-reference inside `release-manifest.json`.

**Prohibited Archive Contents:** Never package `backend/src/`, `backend/test/`, `frontend/src/`, `frontend/test/`, `devDependencies`, `.git/`, `.env` files, Jenkins tokens, AWS credentials, `.pem` keys, or Terraform state/plans.

**Required `release-manifest.json` Fields (Stored Inside Archive — Zero Self-Referential Archive Checksum):**
- `releaseId` (must match Hiera `release_version`, e.g., `20261125T204000Z-<short-sha>`)
- `builtAt` / `builtAtUtc` (non-empty ISO-8601 build timestamp)
- `nodeVersion` (must match major `24.x`, e.g., `v24.13.1`)
- `gitCommit` / `backendCommit` (non-empty build commit identifier; optional `frontendCommit`, `backendVersion`, `frontendVersion`)

### 9.5 Build, Checksum Verification & Rollback Procedure

1. **Pre-Stage Build & External Checksum Calculation (Build Workstation):**
   - Assemble clean `release/` tree (`release-manifest.json` without any `archiveSha256` field, `release/backend/` with `dist/`, `package.json`, `package-lock.json`, and `npm ci --omit=dev` `node_modules/`, plus `release/frontend/dist/`).
   - Create compressed tarball deterministically (`tar -czf git-repo-analyzer-release-<releaseId>.tar.gz release`).
   - Compute checksum **after** tarball creation into the external sidecar:
     ```bash
     sha256sum "git-repo-analyzer-release-${RELEASE_ID}.tar.gz" > "git-repo-analyzer-release-${RELEASE_ID}.tar.gz.sha256"
     ```
2. **Pre-Extraction Checksum Verification Procedure on EC2 2 (Puppet):**
   - If `/opt/git-repo-analyzer/releases/<releaseId>/.extracted.ok` already exists on disk (e.g., normal steady-state run or rollback to a retained known-good release), skip re-verification/extraction so activation needs neither tarball rebuild nor retransfer.
   - Otherwise, before invoking `tar`:
     1. Require both `/var/cache/git-repo-analyzer/staging/git-repo-analyzer-release-<releaseId>.tar.gz` and `.tar.gz.sha256` to exist.
     2. Compare the 64-hex digest recorded inside `.tar.gz.sha256` strictly against Puppet Hiera's authoritative `application::release::expected_sha256` (fail closed on mismatch — preventing tampering even if both staging files were replaced together).
     3. Run `(cd /var/cache/git-repo-analyzer/staging && sha256sum -c --strict "git-repo-analyzer-release-${RELEASE_ID}.tar.gz.sha256")` — fail closed on non-zero exit without extracting.
     4. Extract cleanly into a temp dir under `/opt/git-repo-analyzer/releases/`, enforce permissions (`root:gitrepo` `0750`/`0640` on `backend/`, `root:www-data` `0750`/`0640` on `frontend/dist/`), write `.extracted.ok`, and atomically rename to `/opt/git-repo-analyzer/releases/<releaseId>`.
3. **Controlled 11-Step Activation Sequence, Runtime Consistency & Rollback Strategy:**
   - **Why Zero Downtime Is Not Claimed:** EC2 2 (`t3.micro`) runs one single-process `git-repo-analyzer-backend` (`FileAnalysisStore` on local JSON disk) behind one NGINX vhost. Switching `/opt/git-repo-analyzer/current` updates NGINX static files immediately while the running Node process still serves the previous release in memory until systemd completes its restart. Rather than claiming zero downtime, Puppet enforces a brief controlled HTTP `503 MAINTENANCE` window across public port `80` whenever activating or recovering an unpromoted release.
   - **11-Step Activation Sequence:** (1) `prepare` extracts/validates the release off-path and stamps/verifies `<meta name="app-release-id">` while the previous release keeps serving; (2) `enter-maintenance` atomically writes `/opt/git-repo-analyzer/maintenance.flag` + `state.maintenance.active = true` (port `80` returns `503` + `Retry-After: 5` on `/`, `/assets/*`, `/api/*`); (3) `activate` updates invariant `backend`/`dist` child links, records `pendingActivation.serviceSynced = false`, and switches `/opt/git-repo-analyzer/current` via **one** atomic `os.replace()` syscall; (4) `app_sync_backend_restart` $\rightarrow$ `Service['git-repo-analyzer-backend']` restarts Node onto the new release (`app_mark_service_synced` persists `serviceSynced = true`); (5) `app_verify_backend_health_gate` verifies `127.0.0.1:3000/api/health` (`200 UP` + `releaseId == X`); (6) `Class['application::nginx']` converges/reloads NGINX; (7) `app_verify_frontend_health_gate` probes internal loopback `127.0.0.1:8081/` + proxied `/api/health` verifying both HTML `app-release-id` and running backend `releaseId` match `X`; (8) `app_promote_release` atomically persists `currentKnownGood` / `previousKnownGood`; (9) `app_exit_maintenance` re-verifies backend + verify listener, unlinks `maintenance.flag`, immediately probes public port `80` (re-arming `maintenance.flag` automatically if public check fails), and clears `state.maintenance.active = false`; (10) `app_prune_releases` removes excess directories (`> retain_releases`) **strictly after** promotion and maintenance clearance.
   - **Failure, `SIGKILL` & Auto-Revert Invariants:** Any `SIGKILL` pre/post `os.replace(current)`, backend restart failure, frontend health/mismatch failure, or `SIGKILL` pre/post `unlink(maintenance.flag)` leaves `currentKnownGood` unmutated, blocks promotion and pruning, and ensures either `maintenance.flag` stays active (`503`) or `state.maintenance.active == true` triggers `app_enter_maintenance` to re-arm `maintenance.flag` at the start of the next Puppet convergence run before restarting/verifying the backend. Failed health/integrity checks with `--revert-on-fail` immediately revert `/opt/git-repo-analyzer/current` back to `currentKnownGood`, restart/reload services cleanly, and preserve maintenance gating.
   - **Puppet Hiera Rollback (Zero Rebuild / Zero Retransfer):** Persistent analysis state (`analyses.json` and PNG charts) lives externally in `/var/lib/git-repo-analyzer/data` (`gitrepo:gitrepo`, `0750`) and retained known-good release directories remain intact with validated `.extracted.ok` + `release-manifest.json`. Rolling back requires only updating Hiera (`application::release_version` and `application::expected_sha256`) to `<prev-release-id>` and running Puppet (`puppet agent -t`), which follows the exact same maintenance-gated activation and runtime parity sequence without rebuilding or retransferring tarballs.

---

## 10. Puppet Phase 5B Module Structure & Execution Dependencies

Target node block in `puppet/manifests/site.pp` (`node 'app-server'`):

1. `common` -> `nrpe::client` -> `nagios` (already implemented in Phase 5A).
2. **`application::nodejs`**: Configures the signed NodeSource Node.js 24 LTS repository (`node_24.x` / `nodistro`) and installs `Package['nodejs']` providing `/usr/bin/node` (live installation on EC2 2 deferred to Boundary B).
3. **`application::release`**: Ensures system identity `Group['gitrepo']`/`User['gitrepo']` and parent directories exist, verifies `.sha256` sidecar + Hiera digest + `O_NOFOLLOW` TOCTOU-free copy re-hash, extracts the versioned release into `/opt/git-repo-analyzer/releases/<releaseId>`, stamps/verifies frontend `<meta name="app-release-id">`, enters controlled NGINX maintenance (`enter-maintenance`), enforces non-writable permissions (`root:gitrepo` `0750`/`0640` on `backend/`, `root:www-data` `0750`/`0640` on `frontend/dist/`), and atomically switches `/opt/git-repo-analyzer/current` behind invariant `backend` & `dist` links while leaving `/var/lib/git-repo-analyzer/data` untouched.
4. **`application::backend`**:
   - Creates `/var/lib/git-repo-analyzer` (`root:gitrepo`, `0750`), `/var/lib/git-repo-analyzer/data` (`gitrepo:gitrepo`, `0750`), and `/etc/git-repo-analyzer` + `backend.env` (`0640`).
   - Deploys `/etc/systemd/system/git-repo-analyzer-backend.service`, triggers `daemon-reload` when `manage_service => true`, and ensures `git-repo-analyzer-backend.service` restarts synchronously on `current` switch / interrupted `serviceSynced` (`app_sync_backend_restart` $\rightarrow$ `Service` $\rightarrow$ `app_mark_service_synced`) before `app_verify_backend_health_gate`.
5. **`application::nginx`**:
   - Replaces Ansible's baseline `sites-enabled/default` with production SPA (`/var/www/git-repo-analyzer/dist`) + `/api/` reverse-proxy vhost with `maintenance.flag` `503` gating on public port `80` and un-gated internal verification listener `127.0.0.1:8081` (ordered `app_verify_backend_health_gate` $\rightarrow$ `Class['application::nginx']` $\rightarrow$ `app_verify_frontend_health_gate` $\rightarrow$ `app_promote_release` $\rightarrow$ `app_exit_maintenance` $\rightarrow$ `app_prune_releases`).

---

## 11. Work Breakdown: Remaining Phase 5B Implementation vs Boundary B Operations

- **Remaining Local Implementation Work (Phase 5B — Eligible under Approval Boundary A):**
  1. Implement Puppet classes (`application::nodejs`, `application::release`, `application::backend`, `application::nginx`) and Hiera parameters (without real secrets in repo YAML).
  2. Implement local build/package helper script (generating `release/backend/`, `release/frontend/dist/`, `release-manifest.json`, `.tar.gz`, and `.sha256` cleanly).
  3. Add Puppet parser, `puppet-lint`, catalog compilation, DAG/ordering, and fixture idempotency tests matching Phase 5A standards.
- **Work Strictly Requiring Separate Boundary B Authorization (Live Cloud / Remote Hosts):**
  1. Running `terraform apply` to obtain `app_server_public_ip`, `app_server_public_dns`, and `cicd_server_private_ip` (needed to populate `CORS_ORIGIN` and private DNS mappings).
  2. Transferring staged release artifacts into `/var/cache/git-repo-analyzer/staging/` over SSH to EC2 2.
  3. Running `apt` / `puppet agent -t` on EC2 2 to install Node.js 24 LTS (`nodejs`), extract the verified release, start `git-repo-analyzer-backend.service`, and verify live `http://<app_server_public_ip>/api/health`.
- **Values Deferred Further to Phase 7 (CI/CD Integration on EC2 3):**
  - `JENKINS_URL` (`http://<cicd_server_private_ip>:8080` or `http://cicd-server:8080`), `JENKINS_USER` (`backend-service`), `JENKINS_API_TOKEN`, switching `JENKINS_MOCK_MODE=false`, and hardening [`Jenkinsfile`](file:///home/aditya-2274/Git-repo-analyzer/Jenkinsfile) (`-c core.hooksPath=/dev/null`, `--no-recurse-submodules`, timeouts, resource limits, and `post { cleanup { cleanWs() } }`).
- **Accepted Design Limitations:**
  - Single-process `FileAnalysisStore` serialization on `t3.micro` (no clustering per ADR 001/009).
  - Real `LiveJenkinsClient` HTTP calls and Ubuntu 24.04 package convergence remain untested on live hosts until Boundary B / Phase 7.
