# Implementation Plan: Git Repository Analyzer

This document defines the authoritative, dependency-aware, phased implementation roadmap for the Git Repository Analyzer platform. Each phase contains clear prerequisites, actionable subtasks, completion criteria, and verification steps.

---

## 1. Roadmap Overview and Dependency Ordering

To maintain architectural integrity and prevent configuration conflicts, configuration management and application development are ordered with strict dependency discipline. Specifically, Puppet configuration is split into two distinct stages:
- **Phase 5A (Puppet & Monitoring Foundations)** establishes manifest structures, base packages, and monitoring daemons before application development.
- **Phase 6 (Application Development)** builds and tests the Express API and React SPA against a mock Jenkins interface, defining the concrete systemd, NGINX, and environment contracts.
- **Phase 5B (Puppet-Managed Application Configuration)** deploys and enforces the final application runtime, systemd unit, and reverse proxy using the finalized contracts from Phase 6.

```mermaid
flowchart TD
    P1["Phase 1: Inspection & Alignment (Done)"] --> P2["Phase 2: Analyzer Repairs & Container Validation (Done)"]
    P2 --> P3["Phase 3: Terraform Multi-Instance Infrastructure & Networking (Committed)"]
    P3 --> P4["Phase 4: Ansible Bootstrap & Puppet Master/Agent Setup"]
    P4 --> P5A["Phase 5A: Puppet Foundations & Monitoring Prerequisites"]
    P5A --> P6["Phase 6: Application Development (Express API & React Frontend with Mock Jenkins)"]
    P6 --> P5B["Phase 5B: Puppet-Managed Application Configuration (Runtime, Systemd, NGINX Proxy)"]
    P5B --> P7["Phase 7: Jenkins Pipeline Configuration & Live Backend Integration"]
    P7 --> P8["Phase 8: Monitoring Completion & End-to-End Demonstration Verification"]
```

---

## 2. Phase-by-Phase Execution Plan

### Phase 1: Inspection & Documentation (Completed)
- **Objective:** Inspect existing codebase, verify live AWS state, and establish unified project governance.
- **Status:** Complete (2026-11-18). `AGENTS.md` and all `project_docs/` populated.

---

### Phase 2: Analyzer Script Bug Fixes & Container Validation (Completed)
- **Objective:** Fix verified bugs in `analyze2.sh` and ensure zero-commit and interactive support before deploying containers.
- **Status:** Complete (2026-11-18).
- **Subtasks Completed:**
  1. Restored missing functions `show_menu` and `show_commit_summary` in `analyze2.sh`.
  2. Implemented zero-commit detection (`git rev-parse HEAD >/dev/null 2>&1`) and initialized `ZERO_COMMITS=true/false`.
  3. Validated non-interactive mode passes `ZERO="$ZERO_COMMITS"` accurately to `ai/reportGenerator.js`.
  4. Built local Docker image `git-repo-analyzer:phase2-test` from `Dockerfile`.
  5. Tested container execution against active repositories and zero-commit repositories with exit code 0.
- **Verification Evidence:** All tests exited with code 0. Reports, metrics, and charts validated.

---

### Phase 3: Terraform Multi-Instance Infrastructure & Networking (Completed at Code Level)
- **Objective:** Define reproducible Terraform configuration for three dedicated EC2 instances and multi-tier security groups, designed for on-demand provisioning and complete teardown (`terraform apply` $\rightarrow$ demo $\rightarrow$ `terraform destroy`) while preserving the existing S3 backend and enforcing strict cost governance.
- **Status:** **Implementation Complete, Validated, and Committed in `3dc7870`**. Live provisioning operates strictly on demand; `terraform apply` has **NOT** been run. Zero AWS resources currently exist.
- **Prerequisites:** Phase 2 completion, human review and written approval of instance sizing, storage allocation, and projected on-demand session costs.
- **Subtasks Completed:**
  1. Preserved persistent S3 remote backend block in `terraform/main.tf` with `use_lockfile = true` (bucket `git-repo-analyzer-terraform-state-2026`, region `ap-south-1`).
  2. Implemented approved three-instance EC2 architecture in `modules/ec2`:
     - `puppet_server`: `t3.small` (2 vCPU, 2 GB RAM), 15 GB gp3 EBS root volume, tagged `Role = puppet-server`.
     - `app_monitoring`: `t3.micro` (2 vCPU, 1 GB RAM), 15 GB gp3 EBS root volume, tagged `Role = app-monitoring`.
     - `cicd_analysis`: `t3.small` (2 vCPU, 2 GB RAM), 20 GB gp3 EBS root volume, tagged `Role = cicd-analysis`.
     - Fleet Storage Total: Exactly 50 GB gp3 across all 3 nodes (15 GB + 15 GB + 20 GB).
     - Dynamic AMI lookup using Ubuntu 24.04 LTS SSM Parameter Store.
  3. Implemented outbound internet access & directional security groups:
     - Configured `associate_public_ip_address = true` on all 3 instances within Default VPC public subnets (direct outbound connectivity without an expensive NAT Gateway).
     - Ingress strictly locked: SSH (port 22) to operator CIDR /32; Puppet (port 8140) restricted to `app_monitoring_sg` and `cicd_analysis_sg`; Jenkins API (port 8080) restricted to `app_monitoring_sg`; NRPE (port 5666) restricted to `app_monitoring_sg` on both EC2 1 and EC2 3; public HTTP/HTTPS (80/443) on EC2 2 only.
  4. Updated `terraform/output.tf` and `modules/ec2/outputs.tf` to expose instance IDs, public/private IPs, DNS, and dynamic Ansible inventory output (`ansible_inventory_template`).
  5. Validated cleanly with `terraform fmt -check`, `terraform validate`, and `git diff --check`. Committed in `3dc78707a0329774152137fac6a225970793ef3d` on branch `feat/terraform-infrastructure`.
- **Governance & Non-Actions:**
  - `terraform apply` has **NOT** been executed. No remote state object is written to S3 until apply is run.
  - The S3 state bucket is permanent infrastructure and must never be destroyed.

---

### Phase 4: Ansible Bootstrap & Puppet Master/Agent Setup
- **Objective:** Bootstrap base operating systems, configure private networking and swap, establish authentic SSH trust, install Docker CE, and establish Puppet CA trust and agent enrollment across all three instances.
- **Status:** **In Progress under Boundary A (Checkpoints 4.1 & 4.2 Complete at Local Implementation & Fixture Validation Level; Live Execution Pending Boundary B Provisioning).**
- **Prerequisites:** Phase 3 infrastructure provisioned via `terraform apply` after written operator authorization.
- **Canonical Inventory Groups (Matching Terraform Output):**
  ```ini
  [puppet_server]
  puppet-server ansible_host=<public-ip-1> private_ip=<private-ip-1>

  [application]
  app-server ansible_host=<public-ip-2> private_ip=<private-ip-2>

  [cicd]
  cicd-server ansible_host=<public-ip-3> private_ip=<private-ip-3>

  [puppet_agents:children]
  application
  cicd
  ```
- **Subtasks:**
  1. **Checkpoint 4.1: Pre-Execution Environment & Deterministic SSH Configuration**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level**. Live EC2 verification pending Boundary B.
     - Extracted and modeled canonical inventory in `ansible/inventory/hosts.ini` matching canonical group names and host aliases.
     - Implemented dynamic inventory synchronization script `ansible/scripts/sync_terraform_inventory.sh` with canonical group checking and atomic writes (validated across 5 fixture test scenarios: 5/5 PASS).
     - Implemented deterministic SSH host-key authentication script `ansible/scripts/verify_ssh_host_keys.sh` comparing scanned ED25519 public keys against EC2 hypervisor serial console logs (`aws ec2 get-console-output --latest`).
     - Configured polling timeout (`CONSOLE_TIMEOUT_SECONDS`, default 360 seconds) and polling interval (`CONSOLE_POLL_INTERVAL_SECONDS`, default 10 seconds), recognizing this timeout as an operational safeguard against automation script hangs rather than an AWS-guaranteed delivery SLA. Immediate short-circuiting on AWS CLI authentication/authorization errors and cryptographic fingerprint mismatches (validated across 8 fixture test scenarios: 8/8 PASS).
     - Enforced strict host-key checking in `ansible/ansible.cfg`, root `ansible.cfg`, and `ansible/ssh.cfg` targeting project-scoped `ansible/known_hosts` (mode `0600`, git-ignored).
     - Injected `ansible_ssh_common_args` into `group_vars/all.yml` for path resilience across execution working directories.
     - Relocated private key to `~/.ssh/git-repo-analyzer.pem` with mode `0400` outside the repository workspace.
  2. **Checkpoint 4.2: Ansible Common Bootstrap, Private DNS & Swap Allocation**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (16/16 Audit Tests Passed)**. Live host application pending Boundary B.
     - Enhanced `ansible/roles/common` with modular task files (`apt.yml`, `time.yml`, `packages.yml`, `hosts.yml`, `swap.yml`) and defaults (`defaults/main.yml`).
     - Implemented non-destructive APT lock wait logic in `tasks/apt.yml` using non-blocking Python POSIX record locking `fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)` (matching the native `fcntl(F_SETLK)` write lock semantics used by APT and dpkg) to distinguish active POSIX record lock contention from mere file presence on `/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`, and `/var/lib/apt/lists/lock`. Zero destructive process killing. Bounded 300s timeout provides explicit diagnostic identifying contended lock and holding processes. Paired with `lock_timeout: 300` and `cache_valid_time: 3600` in `ansible.builtin.apt`.
     - Configured timezone (`/etc/localtime` link, `/etc/timezone` file) and enabled/started `systemd-timesyncd` in `tasks/time.yml`.
     - Installed essential baseline system packages in `tasks/packages.yml` (`curl`, `wget`, `git`, `unzip`, `ca-certificates`, `gnupg`, `htop`, `jq`, `software-properties-common`, `systemd-timesyncd`, `net-tools`).
     - Configured fleet private DNS entries in `tasks/hosts.yml` via `ansible.builtin.blockinfile`:
       ```text
       <puppet_server_private_ip>   puppet-server.ec2.internal puppet-server puppet
       <app_server_private_ip>      app-server.ec2.internal app-server
       <cicd_server_private_ip>     cicd-server.ec2.internal cicd-server
       ```
       Private IP addresses are derived strictly and dynamically from the Terraform-generated inventory host variables (`hostvars[host]['private_ip']`) with pre-flight assertions in `hosts.yml`. Removed hardcoded static fallbacks (`10.0.0.x`), ensuring inventory is the single source of truth across IP reassignments.
     - Implemented safe, idempotent, non-destructive swapfile configuration in `tasks/swap.yml` adhering strictly to approved per-instance settings:
       - EC2 1 (`puppet-server`): `swap_size_mb: 0` (swap disabled; all swap tasks skipped).
       - EC2 2 (`app-server`): `swap_size_mb: 1024` (1.0 GB swap shock-absorber on 15 GB EBS).
       - EC2 3 (`cicd-server`): `swap_size_mb: 2048` (2.0 GB swap cushion on 20 GB EBS).
       - Enforces strict safety assertions: fails safely if `/swapfile` exists as a directory or symbolic link, preserves existing valid swapfiles without reallocating or reformatting, creates missing swapfile with configured size and mode `0600`, fails safely if existing file size does not match configured `swap_size_mb * 1024 * 1024` bytes (preventing unsafe truncation/resize), validates `TYPE="swap"` signature via `blkid -p` before activation (rejecting unformatted or foreign files), inspects active swaps via `swapon --show=NAME` to avoid duplicate swapon, updates `/etc/fstab` idempotently via `lineinfile`, and leaves zero-swap nodes completely untouched.
     - Verified locally via comprehensive 16-scenario fixture audit suite `ansible/tests/test_common_role.sh` covering dynamic IP derivation, dynamic IP update resilience, idle lock file non-contention, active POSIX lock contention between independent processes, continuation after lock release, bounded timeout diagnostics, zero-swap host preservation, valid swapfile preservation, directory rejection, symlink rejection, missing swap creation, incorrect size rejection without modification, missing signature rejection without modification, active swap duplicate skip, idempotent `/etc/fstab` updates, and dual-directory playbook syntax checks (16/16 PASS).
  3. **Checkpoint 4.3: Puppet Server Installation & Cryptographic CA Initialization (EC2 1)**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (20/20 Tests Passed; Ubuntu 24.04 Package Compatibility Audit & Vendor Repository Pinning Verified)**. Live host application pending Boundary B.
     - Implemented dedicated Ansible role `ansible/roles/puppet_server/` with modular task organization: `preflight.yml`, `repository.yml`, `jvm.yml`, `config.yml`, `ca.yml`, `service.yml`, and `handlers/main.yml`.
     - Preflight task validates target distribution (`Ubuntu 24.04 LTS Noble`) and inventory targeting (`puppet-server` in `[puppet_server]`).
     - Conducted technical audit comparing Ubuntu Noble Universe package (`8.4.0-1`) vs PuppetLabs Upstream Vendor Package (`8.7.0-1jammy`): confirmed Universe package fractures filesystem hierarchy (`/usr/bin/puppetserver`, `/etc/puppet/`), collides with official `puppet-agent`, and freezes updates at 8.4.0. Selected official PuppetLabs package (pure Java bytecode, OpenJDK 17) which conforms strictly to vendor paths (`/opt/puppetlabs/bin/puppetserver`, `/etc/puppetlabs/puppetserver/`).
     - Configured APT pinning `/etc/apt/preferences.d/puppetlabs.pref` pinning `origin apt.puppet.com` with priority 900 (superseding distro priority 500). Enhanced candidate detection using `apt-cache madison puppetserver | grep -E 'apt\.puppet\.com.*noble'` to avoid false positives from distro universe archive.
     - JVM tuning task updates `/etc/default/puppetserver` to `-Xms1g -Xmx1g` while preserving existing JVM options, and configures `max-active-jrubies: 1` in `/etc/puppetlabs/puppetserver/conf.d/puppetserver.conf`.
     - Configuration task deploys `/etc/puppetlabs/puppet/puppet.conf` with stable identities (`certname = puppet-server`, `server = puppet-server`, `dns_alt_names = puppet-server,puppet-server.ec2.internal,puppet`) and security policies (`autosign = false`).
     - Cryptographic CA task implements strict 3-state CA validation:
       - *State A (Uninitialized)*: If neither `ca_crt.pem` nor `ca_key.pem` exists, executes `/opt/puppetlabs/bin/puppetserver ca setup`.
       - *State B (Initialized & Valid)*: If all CA files exist, verifies `openssl x509 -checkend 0` and cryptographic modulus equality between `ca_crt.pem` and `ca_key.pem`; skips setup idempotently preserving existing keys and certificates.
       - *State C (Inconsistent/Corrupt)*: If cert exists without key, key without cert, metadata missing, cert expired, or certificate modulus does not match private key modulus, fails fast with an explicit error. Automatic regeneration and `--force` are strictly prohibited.
     - Service management task enables and starts `puppetserver`, verifies TCP port 8140 availability via `wait_for`, and checks CA health via `puppetserver ca status`.
     - Verified locally via isolated fixture test suite `ansible/tests/test_puppet_server_role.sh` (20/20 PASS).
  4. **Checkpoint 4.4: Puppet Agent Installation (EC2 2 & EC2 3)**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (25/25 Tests Passed)**. Live host application pending Boundary B.
     - Implemented dedicated Ansible role `ansible/roles/puppet_agent/` with modular task structure: `preflight.yml`, `repository.yml`, `install.yml`, `config.yml`, `csr.yml`, `service.yml`, `defaults/main.yml`, and `handlers/main.yml`.
     - Preflight task validates target OS (`Ubuntu 24.04 LTS Noble`), inventory targeting (`app-server` on EC2 2, `cicd-server` on EC2 3), resolves `puppet-server` against expected private IP from inventory, and tests TCP 8140 reachability with actionable diagnostics.
     - Repository task installs official `puppet8-release-noble.deb` and enforces APT priority pinning (`/etc/apt/preferences.d/puppetlabs.pref` pinning `origin apt.puppet.com` @ 900 > 500) to reject Ubuntu Universe's distro package. No Jammy fallback is needed or used (native Noble `puppet-agent` package published by vendor).
     - Installation task installs official `puppet-agent` package and validates binary executable path `/opt/puppetlabs/bin/puppet`.
     - Configuration task non-destructively manages `/etc/puppetlabs/puppet/puppet.conf` via `community.general.ini_file`: configures `server = puppet-server`, stable certnames (`app-server` on EC2 2, `cicd-server` on EC2 3), `runinterval = 30m`, preserves custom options, and ensures `autosign` is strictly absent.
     - CSR submission task implements controlled registration:
       - Preserves existing valid certificates and skips submission (zero key/cert regeneration).
       - Fails fast safely if existing certificate identity conflicts with inventory certname or is corrupted/mismatched.
       - Submits CSR via `/opt/puppetlabs/bin/puppet ssl submit_request --server puppet-server` when no certificate exists.
       - Verifies that local CSR exists and subject CN strictly matches expected certname (`app-server` or `cicd-server`).
       - Enforces strict security boundaries: zero autosigning, zero CA signing (signing belongs exclusively to Checkpoint 4.5), zero CA private key copying, zero key sharing between nodes, and zero destructive SSL removal.
     - Service task manages `puppet` systemd unit (enabled=true, state=started) with configuration handler notification.
     - Created test playbook `ansible/playbooks/test-puppet-agent.yml` and comprehensive fixture test suite `ansible/tests/test_puppet_agent_role.sh` (25/25 PASS). All 5 project test suites pass (74/74 checks).
  5. **Checkpoint 4.5: Puppet CA Verification & Strict CSR Enrollment**:
     - On agent nodes, run `/opt/puppetlabs/bin/puppet ssl verify`. If valid, skip CSR submission.
     - If not verified, execute `/opt/puppetlabs/bin/puppet ssl submit_request --server puppet-server`.
     - On EC2 1, execute `/opt/puppetlabs/bin/puppetserver ca list --all --format json` and parse JSON array.
     - Enforce whitelist security check: ensure only `app-server` and `cicd-server` are present; fail on unknown CSRs.
     - Sign approved certificates individually: `/opt/puppetlabs/bin/puppetserver ca sign --certname <node>`.
     - On agents, enforce catalog via `/opt/puppetlabs/bin/puppet agent -t --detailed-exitcodes`.
     - Ansible handles exit codes: `failed_when: result.rc not in [0, 2]`, `changed_when: result.rc == 2`.
  6. **Checkpoint 4.6: Docker Engine & Compose Bootstrap (EC2 3)**:
     - Install official Docker CE and Compose plugin from Docker's Ubuntu Noble repository.
     - Add `ubuntu` user to the `docker` group. (Adding `jenkins` user is deferred to Phase 7).
     - Verify Docker daemon status via `systemctl status docker`.
  7. **Checkpoint 4.7: NGINX Bootstrap Baseline (EC2 2)**:
     - Deploy baseline NGINX package on EC2 2.
     - Confirm service is active and responds on port 80.
- **Completion Criteria:**
  - All 3 instances respond to Ansible ping with strict host-key verification.
  - Puppet Server active with tuned 1 GB JVM heap.
  - Both agents enrolled with cryptographically verified SSL certificates.
  - `puppet agent -t --detailed-exitcodes` exits with code 0 or 2 on both agent nodes.
  - Docker CE operational on EC2 3.
  - NGINX baseline running on EC2 2.

---

### Phase 5A: Puppet Foundations & Monitoring Prerequisites
- **Objective:** Establish foundational Puppet module and manifest directory structures on EC2 1, deploy foundational monitoring daemons (NRPE) on agent nodes, prepare Nagios Core prerequisites on EC2 2, and formalize Ansible-to-Puppet ownership handovers.
- **Prerequisites:** Phase 4 completion (Puppet agents communicating with Puppet Server).
- **Subtasks:**
  1. **Puppet Environment Structure (`/etc/puppetlabs/code/environments/production/`)**:
     - Set up `manifests/site.pp` and standard module paths (`modules/common`, `modules/monitoring`, `modules/nrpe`).
  2. **Foundational Node Configurations (`site.pp`)**:
     - `node 'puppet-server'`: Manage base packages, Puppet Server service monitoring, and local firewall sanity.
     - `node 'app-server'`: Manage base packages, monitoring prerequisites (compilation tools for Nagios plugins), and baseline directories.
     - `node 'cicd-server'`: Manage base packages, Docker daemon service monitoring, and baseline directories.
  3. **NRPE Daemon Deployment via Puppet**:
     - Deploy Puppet module `nrpe` targeting EC2 1 and EC2 3.
     - Install `nagios-nrpe-server` and `nagios-plugins`.
     - Configure `/etc/nagios/nrpe.cfg`: restrict `allowed_hosts` strictly to `app-server` private IP (`<private-ip-2>`).
     - Deploy base NRPE check definitions: `check_disk`, `check_load`, `check_procs`.
     - Start and enable `nagios-nrpe-server` service; verify port 5666 responds to EC2 2.
  4. **Nagios Core Prerequisites Deployment (EC2 2)**:
     - Install Nagios build dependencies (`build-essential`, `libgd-dev`, `apache2`, `apache2-utils`).
     - Configure Apache loopback virtual host binding strictly to `127.0.0.1:8080`.
     - Configure HTTP Basic Authentication file (`/etc/nagios/htpasswd.users`) for `nagiosadmin`.
  5. **Formalize Ansible Handover Boundary**:
     - Tag baseline files as Puppet-managed (`# Managed by Puppet - Do not edit manually or with Ansible`).
- **Completion Criteria:**
  - Puppet catalog compiles cleanly and enforces base desired state on all nodes.
  - NRPE daemon active on EC2 1 and EC2 3, strictly accepting queries from EC2 2.
  - Apache loopback active on EC2 2 on port 8080 with basic authentication configured.
  - Zero application service or reverse proxy configuration deployed yet (deferred to Phase 5B).

---

### Phase 6: Application Development (Backend API & Frontend UI with Mock Jenkins)
- **Objective:** Develop the complete Node.js/Express backend API and React/Vite single-page application in the local repository, validate against a mock Jenkins client, author automated unit/integration tests, and establish finalized contracts for systemd, NGINX, and environment variables.
- **Prerequisites:** Phase 5A completion.
- **Subtasks:**
  1. **Backend Implementation (`backend/`)**:
     - Initialize TypeScript Node.js project: `package.json`, `tsconfig.json`.
     - Implement URL validator and SSRF guard (`src/validators/repoValidator.ts`):
       - Parse URL using Node `URL` constructor.
       - Enforce HTTPS protocol and exact hostname `github.com`.
       - Reject embedded credentials, unexpected ports, query strings, and fragments.
       - Reject loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`), AWS metadata (`169.254.169.254`), and RFC 1918 private CIDRs.
     - Implement Jenkins client abstraction (`src/services/jenkinsClient.ts`):
       - `IJenkinsClient` interface with methods: `triggerJob`, `getBuildFromQueue`, `getBuildStatus`, `fetchArtifact`.
       - `MockJenkinsClient`: Simulates build queue (2s delay), execution (5s delay), and returns fixture metrics/reports for standalone development and testing.
       - `LiveJenkinsClient`: Interacts with Jenkins REST API over private network using HTTP basic authentication.
     - Implement canonical resource-oriented API routes (`src/routes/analyses.ts`):
       - `GET /api/health`: Health status.
       - `POST /api/analyses`: Accepts `{ "repositoryUrl": "..." }`, validates input, generates UUID v4 `analysisId` (`550e8400-e29b-41d4-a716-446655440000`), dispatches build, returns HTTP 202 Accepted.
       - `GET /api/analyses/:id`: Returns HTTP 200 with strictly application-level metadata (`analysisId`, `status`, `progress`, `createdAt`, `updatedAt`, `error`). The backend internally manages the mapping (`analysisId` $\rightarrow$ `queueId` $\rightarrow$ `buildNumber`) and strictly conceals Jenkins build identifiers from clients.
       - `GET /api/analyses/:id/results`: Returns HTTP 200 with parsed `metrics.json`, Markdown text, and chart references.
     - Author unit and integration tests (`test/analyses.test.ts`) validating API contracts, SSRF rejection, and mock build progression.
  2. **Frontend Implementation (`frontend/`)**:
     - Scaffold React application using Vite, TypeScript, and Tailwind CSS.
     - Implement components: `RepoInputForm.tsx` (URL validation feedback), `AnalysisProgress.tsx` (polling hook with backoff), `MetricCards.tsx` (scorecards), `ActivityCharts.tsx` (Recharts & PNG views), `MarkdownReport.tsx` (report viewer).
     - Configure production build (`npm run build`) compiling optimized static bundle to `frontend/dist/`.
  3. **Finalize Infrastructure Contracts for Puppet Phase 5B**:
     - Execution User: Dedicated unprivileged service user `gitrepo`, group `gitrepo`.
     - Environment Directory: `/etc/git-repo-analyzer` (`root:gitrepo`, mode `0750`).
     - Environment File: `/etc/git-repo-analyzer/backend.env` (`root:gitrepo`, mode `0640` - root read/write, group read-only, others none).
     - Systemd Unit: `/etc/systemd/system/git-repo-analyzer-backend.service` (`User=gitrepo`, `Group=gitrepo`, `EnvironmentFile=/etc/git-repo-analyzer/backend.env`).
     - NGINX Routing: `/` serves `/var/www/git-repo-analyzer/dist`; `/api/` proxies to `http://127.0.0.1:3000/api/`.
     - Environment Variables: `PORT=3000`, `NODE_ENV=production`, `JENKINS_URL`, `JENKINS_USER`, `JENKINS_API_TOKEN`, `JENKINS_MOCK_MODE`.
- **Completion Criteria:**
  - Backend unit and integration tests pass with 100% success against `MockJenkinsClient`.
  - Frontend builds cleanly (`npm run build`) without TypeScript or linter errors.
  - End-to-end user workflow validated locally using mock data.
  - Systemd, NGINX, and environment file contracts finalized for Puppet manifest authoring.

---

### Phase 5B: Puppet-Managed Application Configuration
- **Objective:** Author and apply Puppet manifests to deploy the Node.js 20 LTS runtime, backend systemd service unit, NGINX virtual hosts, and environment configurations on EC2 2 based on the finalized contracts from Phase 6.
- **Prerequisites:** Phase 6 completion (application artifacts and contracts verified).
- **Subtasks:**
  1. **Deploy Node.js Runtime via Puppet (`modules/application/manifests/nodejs.pp`)**:
     - Deploy NodeSource Node.js 20 LTS repository on EC2 2; install `nodejs`.
  2. **Deploy Application Files and Systemd Unit (`modules/application/manifests/backend.pp`)**:
     - Ensure system group and user `gitrepo` exist (`--system --no-create-home`).
     - Create application directories: `/opt/git-repo-analyzer/backend` (`gitrepo:gitrepo`, `0755`), `/var/www/git-repo-analyzer` (`www-data:www-data`, `0755`), `/etc/git-repo-analyzer` (`root:gitrepo`, `0750`).
     - Deploy environment file `/etc/git-repo-analyzer/backend.env` (`root:gitrepo`, mode `0640`, mode initially set to `JENKINS_MOCK_MODE=true` until Phase 7).
     - Deploy systemd unit file `/etc/systemd/system/git-repo-analyzer-backend.service` (`User=gitrepo`, `Group=gitrepo`).
     - Ensure service is enabled and running.
  3. **Deploy NGINX Reverse Proxy Configuration (`modules/application/manifests/nginx.pp`)**:
     - Deploy production virtual host configuration on port 80/443.
     - Configure static file serving for React SPA from `/var/www/git-repo-analyzer/dist` with `try_files $uri $uri/ /index.html`.
     - Configure reverse proxy for `/api/` targeting `http://127.0.0.1:3000/api/` with proxy buffer headers.
     - Test NGINX configuration syntax and restart service.
  4. **Enforce Catalog and Verify Convergence**:
     - Run `puppet agent -t --detailed-exitcodes` on EC2 2. Verify exit code is 2 (applied) on first run and 0 (idempotent) on rerun.
     - Verify local HTTP response: `curl -s http://127.0.0.1/api/health` returns `UP`.
- **Completion Criteria:**
  - Node.js 20 LTS active on EC2 2.
  - Backend systemd service running as `gitrepo` user and managed by Puppet.
  - NGINX serving frontend assets and proxying `/api/` requests to Express.
  - Puppet catalog converges cleanly with zero errors.

---

### Phase 7: Jenkins Pipeline Configuration & Real Backend Integration
- **Objective:** Provision Jenkins Controller on EC2 3, configure parameterized pipeline executing the Dockerized analyzer container, establish Jenkins API credentials, and switch the Express backend from mock mode to live Jenkins execution.
- **Prerequisites:** Phase 5B completion (application running on EC2 2; Docker running on EC2 3).
- **Subtasks:**
  1. **Jenkins Installation & System Configuration (EC2 3)**:
     - Install OpenJDK 17 headless and official Jenkins LTS repository package on EC2 3.
     - Tune Jenkins JVM heap in `/etc/default/jenkins` or systemd override: `JAVA_ARGS="-Xms384m -Xmx512m"`.
     - Add `jenkins` system user to the `docker` group (`usermod -aG docker jenkins`).
     - Start and enable `jenkins` service; verify port 8080 listens locally.
  2. **Pipeline Job Configuration**:
     - Create parameterized pipeline job `git-repo-analyzer` loaded with repository `Jenkinsfile`.
     - Parameter: `REPO_URL` (String).
     - Configure secret credential in Jenkins Credentials Store: `groq-api-key` (Secret text) for AI report generation.
     - Verify Docker execution: Jenkins executes `docker run --rm --user $(id -u):$(id -g) -v $WORKSPACE/target-repo:/repo adityaashok2274/git-repo-analyzer:latest`.
     - Confirm Docker socket (`/var/run/docker.sock`) is never mounted inside the analyzer container.
  3. **Backend Integration & Credential Configuration**:
     - Generate an API token for user `backend-service` on Jenkins.
     - Update `/etc/git-repo-analyzer/backend.env` on EC2 2:
       ```ini
       PORT=3000
       NODE_ENV=production
       JENKINS_URL=http://<private-ip-3>:8080
       JENKINS_USER=backend-service
       JENKINS_API_TOKEN=<token>
       JENKINS_MOCK_MODE=false
       ```
     - Restart backend systemd service: `systemctl restart git-repo-analyzer-backend`.
  4. **Integration Verification**:
     - Trigger live analysis via backend: `POST /api/analyses` with `https://github.com/owner/repo`.
     - Verify Jenkins job is triggered over internal private network (TCP 8080).
     - Verify Docker container executes analyzer, generates `metrics.json`, `summary.md`, and PNG charts, and Jenkins archives artifacts.
     - Verify backend retrieves artifacts and React displays analysis dashboard.
- **Completion Criteria:**
  - Jenkins executes pipeline successfully without root escalation or Docker socket mounting.
  - Backend retrieves and formats live artifacts from Jenkins API.
  - React frontend displays live analysis results for submitted public repositories.

---

### Phase 8: Monitoring Completion & End-to-End System Verification
- **Objective:** Finalize Nagios Core monitoring definitions, verify remote NRPE telemetry over TCP 5666, test administrative SSH tunneling, perform disaster recovery and configuration drift tests, and validate teardown.
- **Prerequisites:** Phase 7 completion.
- **Subtasks:**
  1. **Finalize Nagios Host and Service Definitions (EC2 2)**:
     - Configure `/etc/nagios/objects/hosts.cfg`:
       - `puppet-server` (`<private-ip-1>`): ping, SSH (port 22), port 8140 check, NRPE checks (CPU load, disk, RAM).
       - `app-server` (`127.0.0.1`): ping, NGINX process, Node.js backend process, disk space, frontend HTTP response.
       - `cicd-server` (`<private-ip-3>`): ping, SSH (port 22), NRPE checks (Docker daemon, Jenkins service, disk space, CPU load).
  2. **Verify Administrative Access via SSH Tunnel**:
     - Establish encrypted SSH tunnel from operator workstation:
       `ssh -i ~/.ssh/git-repo-analyzer.pem -L 8080:127.0.0.1:8080 ubuntu@<app-server-public-ip>`
     - Access `http://localhost:8080/nagios` in browser; authenticate with `nagiosadmin`.
     - Confirm zero public internet exposure for the Nagios interface.
  3. **Configuration Drift and Resilience Testing**:
     - Manually alter NGINX configuration on EC2 2; trigger Puppet run; verify configuration reverts to desired state.
     - Manually stop backend service; verify Nagios transitions to CRITICAL; verify service auto-restart.
  4. **End-to-End System Demonstration Acceptance**:
     - Submit public repositories covering standard repos, high-churn repos, and zero-commit repos.
     - Verify metrics, Markdown reports, and charts render accurately.
  5. **Ephemeral Teardown and Cleanup Validation**:
     - Export desired reports and artifacts to external storage or Git.
     - Execute `terraform destroy` to tear down all 3 EC2 instances and attached EBS volumes.
     - Confirm S3 state bucket (`git-repo-analyzer-terraform-state-2026`) remains intact and unmodified.
- **Completion Criteria:**
  - All Nagios services report `OK` status across all three instances.
  - Puppet catalog enforces desired state without manual intervention.
  - End-to-end demonstration workflow verified.
  - Clean teardown verified with zero orphaned resources.

---

## 3. Strict Security Specification & Control Status

### 3.1 Untrusted Git Repository Input Validation & Sandboxing
Submitted repository URLs and repository contents represent completely untrusted user input. The Express backend and container execution pipeline enforce multi-layered defense-in-depth:

1. **Strict GitHub Hostname Allowlisting**: Only repositories hosted on `github.com` are accepted. Arbitrary Git servers, raw IP addresses, or alternative forge URLs are rejected immediately.
2. **Canonical URL Parsing**: The backend parses input using the standard Node.js `URL` constructor (`new URL(input)`). Regular expressions are used only for secondary path syntax validation.
3. **Rejection of Dangerous URL Components**:
   - Username or password embedded in URLs (e.g., `https://user:pass@github.com/...`) is rejected.
   - Non-standard ports (anything other than default HTTPS port 443) are rejected.
   - Query parameters and URL fragments are stripped and rejected.
   - Non-HTTPS protocols (`http://`, `git://`, `ssh://`, `file://`) are strictly rejected.
4. **Server-Side Request Forgery (SSRF) Protection**:
   - Hostname resolution is validated against restricted IP ranges.
   - Explicitly rejects loopback addresses (`127.0.0.0/8`, `::1`), link-local addresses (`169.254.0.0/16`), AWS Instance Metadata Service (`169.254.169.254`), and RFC 1918 private subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
   - If HTTP redirects occur during cloning or API calls, redirects are validated to ensure they cannot escape to internal network destinations.
5. **Zero Direct Shell Command Interpolation**:
   - User input is never concatenated or interpolated directly into shell strings.
   - Jenkins parameters are passed via structured JSON/form payloads using parameterized API endpoints.
6. **Analyzer Container Isolation & Execution Sandboxing**:
   - **Git Hooks Prohibited**: Git commands strictly specify `-c core.hooksPath=/dev/null` on clone, fetch, and checkout to ensure untrusted `.git/hooks` never execute.
   - **Zero Script/Binary Execution**: The analyzer container strictly inspects Git metadata (`git log`, `git shortlog`, `git rev-parse`) and runs static line counting (`cloc`). No repository scripts, makefiles, or binaries are ever executed.
   - **No Recursive Submodules**: Git clone/fetch enforces `--no-recurse-submodules`.
   - **Execution Timeouts**: Git clone is bounded to 5 minutes; analysis container execution is bounded to 10 minutes.
   - **Resource Limits**: Docker execution enforces `--memory=1g`, `--cpus=1.5`, `--pids-limit=100`, and repository disk allocation is capped at 2 GB.
   - **Non-Root Execution**: Container execution enforces `--user $(id -u):$(id -g)` preventing root ownership or privilege escalation.
   - **Temporary Workspace Hygiene**: Target repository files and temporary data are wiped immediately upon analysis completion.
   - **Credential & Daemon Isolation**: Jenkins credentials are never passed into the container; the host Docker socket (`/var/run/docker.sock`) is **never mounted**.

### 3.2 Jenkins and Docker Host Security
1. **Internal-Only Access**: Jenkins port 8080 is bound exclusively to private networking and accepts connections only from the Application Server security group (`app_monitoring_sg`). Jenkins is completely unreachable from the public internet.
2. **Credential Isolation**:
   - Backend execution user: Dedicated unprivileged system user `gitrepo`, group `gitrepo`.
   - Backend environment directory: `/etc/git-repo-analyzer` (`root:gitrepo`, mode `0750`).
   - Backend environment file: `/etc/git-repo-analyzer/backend.env` (`root:gitrepo`, mode `0640` - root read/write, `gitrepo` group read-only, others none).
   - Jenkins credentials are never exposed in frontend React bundles or network responses.
   - Jenkins credentials are never passed as environment variables into the ephemeral analyzer container.
3. **Docker Daemon Protection**:
   - The host Docker Unix socket (`/var/run/docker.sock`) is **never mounted inside the analyzer container**.
   - Docker group membership on EC2 3 is treated as root-equivalent access and restricted strictly to system users `ubuntu` and `jenkins`.

### 3.3 Security Control Implementation Status
To distinguish design requirements from implemented and verified controls, each control is labeled according to its verified state:

| Security Control | Implementation Category | Status | Verified Evidence / Operational Rule |
| :--- | :--- | :---: | :--- |
| Directional Security Groups | Infrastructure | **IMPLEMENTED** | Ingress rules defined and validated in `terraform/modules/ec2/main.tf` (Commit `3dc7870`). |
| Jenkins Internal Network Isolation | Infrastructure | **IMPLEMENTED** | Port 8080 restricted to `app_monitoring_sg` in Terraform; public access blocked. |
| Strict GitHub Hostname Allowlisting | Application API | **SPECIFIED** | Documented in ADR 009 & Section 3.1; to be implemented in Phase 6 (`src/validators/repoValidator.ts`). |
| Canonical URL Parsing (Node URL API) | Application API | **SPECIFIED** | Documented in Section 3.1; to be implemented in Phase 6. |
| Rejection of Embedded Credentials & Ports | Application API | **SPECIFIED** | Documented in Section 3.1; to be implemented in Phase 6. |
| SSRF Defense (Metadata, Private IP, Redirects) | Application API | **SPECIFIED** | Documented in Section 3.1; to be implemented in Phase 6. |
| Zero Shell Command Interpolation | Application API | **SPECIFIED** | Parameterized Jenkins API dispatch designed; to be implemented in Phase 6. |
| Execution User & Restrictive Permissions | Host OS / Service | **SPECIFIED** | User `gitrepo`, `/etc/git-repo-analyzer/backend.env` mode `0640`; to be deployed in Phase 5B. |
| Analyzer Container Non-Root User | Container Engine | **TESTED** | Verified in Phase 2 container testing (`docker run --user $(id -u):$(id -g)`). |
| Docker Socket Mount Prohibition | Container Engine | **IMPLEMENTED** | `Jenkinsfile` and `analyze2.sh` verified: socket `/var/run/docker.sock` is not mounted. |
| Git Hooks Disabled (`core.hooksPath=/dev/null`) | Container Engine | **SPECIFIED** | To be enforced in `Jenkinsfile` / container analysis invocation. |
| Recursive Submodules Disabled | Container Engine | **SPECIFIED** | To be enforced in `Jenkinsfile` clone stage. |
| Execution Timeouts & Resource Caps | Container Engine | **SPECIFIED** | 5m clone timeout, 10m container timeout, `--memory=1g` to be enforced in Phase 7. |
| Ephemeral Container Cleanup | Container Engine | **IMPLEMENTED** | Docker run specifies `--rm` in `Jenkinsfile`; container runtime filesystem is discarded on exit. |
| Host Workspace Directory Cleanup (All Paths) | CI/CD Pipeline | **SPECIFIED** | Currently only pre-build `rm -rf target-repo` exists in `Jenkinsfile`; post-build cleanup via `post { cleanup { cleanWs() } }` covering success, failure, abort, and timeout paths is to be implemented and tested in Phase 7. |

---

## 4. Resource Sizing, Workload Modeling & Governance

All performance, memory, and timing metrics are **provisional pre-deployment estimates** derived from static component profiling. Live empirical metrics will be captured during Phase 4 and Phase 7 testing.

```text
EC2 1: Dedicated Puppet Server (t3.small: 2.0 GB Physical RAM, 15 GB gp3 EBS) [ESTIMATE]
• OS Base + Systemd + Kernel: ~250 MB
• JVM Heap (-Xms1g -Xmx1g, max-active-jrubies: 1): 1024 MB
• JVM Metaspace, Thread Stacks & Native Overhead: ~200 MB
• Estimated Steady-State Memory: ~1.47 GB ──► Free Physical Headroom: ~530 MB

EC2 2: App + Monitoring Server (t3.micro: 1.0 GB Physical RAM, 15 GB gp3 EBS + 1.0 GB Swap) [ESTIMATE]
• OS Base: ~220 MB │ NGINX: ~20 MB │ Node.js Express: ~120 MB │ Nagios Core: ~30 MB │ Apache: ~50 MB
• Estimated Steady-State Memory: ~440 MB ──► Free Physical Headroom: ~560 MB
• Estimated Peak Run (+ Puppet Agent ~250 MB): ~690 MB ──► Free Headroom: ~310 MB (Swap in-use: < 50 MB)

EC2 3: CI/CD & Analysis Server (t3.small: 2.0 GB Physical RAM, 20 GB gp3 EBS + 2.0 GB Swap) [ESTIMATE]
• OS Base: ~250 MB │ Docker Daemon: ~120 MB │ NRPE: ~15 MB │ Jenkins JVM (-Xms384m -Xmx512m): ~520 MB
• Estimated Steady-State Memory: ~905 MB ──► Free Physical Headroom: ~1.09 GB
• Estimated Peak Run (+ Analyzer Container ~350 MB + Agent ~250 MB): ~1.50 GB ──► Free Headroom: ~500 MB
```

### Operational Risks by Instance
1. **EC2 1 (Puppet Server — `t3.small`, 2 GB RAM)**:
   - *Operational Risk*: Default Puppet Server 8 configuration requires a 2 GB JVM heap, which would trigger an immediate kernel OOM panic on a 2 GB VM. Tuning down to `-Xms1g -Xmx1g` with `max-active-jrubies: 1` fits steady-state within ~1.47 GB. However, JVM Metaspace expansion, thread stack accumulation, or concurrent catalog compilation requests from multiple agents could deplete the ~530 MB physical headroom.
   - *Mitigation & Monitoring*: Strictly enforce `max-active-jrubies: 1`; splay agent run schedules; monitor `MemAvailable`, swap, and JVM garbage collection activity.
2. **EC2 2 (Application + Monitoring Server — `t3.micro`, 1 GB RAM)**:
   - *Operational Risk*: Most memory-constrained node in the fleet. Baseline steady-state consumes ~440 MB (leaving ~560 MB headroom). When Puppet Agent executes its catalog run (+250 MB), usage surges to ~690 MB (~70% of physical capacity). If inbound API traffic spikes, Nagios executes intensive concurrent plugin checks, or Node.js encounters memory leaks, the instance risks memory paging thrashing or process termination by the OOM killer.
   - *Mitigation & Monitoring*: Ansible configures a 1.0 GB swapfile strictly as an emergency shock-absorber; configure Puppet Agent with random sleep (splay); monitor RSS memory, swap in-use (`< 50 MB`), and process count.
3. **EC2 3 (CI/CD & Analysis Server — `t3.small`, 2 GB RAM)**:
   - *Operational Risk*: Concurrent workload spikes. The Jenkins controller JVM (~520 MB) running alongside an ephemeral Docker analyzer container (bounded to 1 GB via `--memory=1g`, ~350 MB typical) and a concurrent Puppet Agent catalog run (~250 MB) consumes ~1.50–1.80 GB RAM, leaving minimal physical headroom. Unbounded concurrent builds or runaway container processes could trigger system-wide contention.
   - *Mitigation & Monitoring*: Restrict Jenkins to a single build executor (`# of executors = 1`) ensuring strictly sequential pipeline execution; enforce container limits (`--memory=1g`, `--cpus=1.5`, `--pids-limit=100`); Ansible configures a 2.0 GB swapfile cushion.
4. **Fleet-Wide T3 CPU Credit Exhaustion Risk**:
   - *Operational Risk*: T3 instances operate in Unlimited mode. Initial bootstrap activities (Puppet Server startup, package compilation, Docker pull, Jenkins initialization) cause sustained CPU bursts that deplete initial launch credits. Once credits reach zero, surplus CPU credits are billed at $0.05 per vCPU-hour.
   - *Mitigation & Monitoring*: Track credit burn rate via CloudWatch telemetry and stagger bootstrap tasks where practical.

### Workload Thresholds & Monitored Metrics
- **Swap Limits**: Steady-state swap in-use must remain `< 50 MB` (near 0 MB). Transient peak during catalog compilation must not exceed `< 200 MB`. Swap is an emergency buffer against kernel OOM panics, not physical memory expansion.
- **CPU Credit Dynamics**: T3 instances run in Unlimited mode. We make **no guarantee** that baseline credits sustain a four-hour demonstration without surplus credit charges ($0.05/vCPU-hour).
- **Active Live Metrics to Measure During Deployment**:
  - **CloudWatch Metrics**: `CPUCreditBalance`, `CPUSurplusCreditCharged`, `CPUUtilization`, `NetworkIn`, `NetworkOut`.
  - **Host OS Telemetry**: 1-minute, 5-minute, 15-minute load averages via `/proc/loadavg`; memory distribution via `/proc/meminfo` (`MemAvailable`, `SwapTotal`, `SwapFree`); swap activity via `vmstat 1 5`.
  - **Process-Level Profiles**: Top memory consumers via `ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -15`.
  - **Docker Engine Stats**: Real-time container memory and CPU utilization via `docker stats --no-stream`.
- **Sizing Decision Policy**: Retain provisional sizing (`t3.small` / `t3.micro` / `t3.small`) without resizing until empirical telemetry captured during live Phase 4 and Phase 7 deployments provides verified data justifying adjustments.

---

## 5. Two-Tier Approval Boundaries

To ensure strict cost governance under ADR 010, the project separates implementation authorizations from infrastructure provisioning:

- **Approval Boundary A (Phase Implementation Approval)**:
  - Grants authorization to create or modify local codebase files, Ansible roles, Puppet manifests, unit/integration tests, and documentation.
  - Does **NOT** authorize live cloud deployment, AWS resource creation, or financial charges.
- **Approval Boundary B (AWS Provisioning Approval)**:
  - Grants explicit, written authorization to execute `terraform apply` and provision billable EC2 instances, EBS storage, and public IP allocations.
  - Requires pre-deployment checklist sign-off and session cost review.
  - Grants authorization to run live Ansible playbooks against provisioned EC2 instances.
- **Non-Negotiable Rule**: Approval for Boundary A **never implies** approval for Boundary B. Authoring Phase 4 code proceeds under Boundary A; running `terraform apply` requires explicit Boundary B approval.

---

## 6. Pre-Deployment Readiness Checklist

Before executing `terraform apply` or provisioning live AWS resources under Boundary B, the following formal checklist must be verified:

- [ ] **1. SSH Operator CIDR**: Variable `var.allowed_ssh_cidr` configured with a strict `/32` subnet matching the operator's verified public IPv4 address.
- [ ] **2. AWS Key Pair**: Key pair named `git-repo-analyzer` exists in region `ap-south-1`.
- [ ] **3. Private Key Relocation & Security**:
  - Current verified location: `/home/aditya-2274/Git-repo-analyzer/git-repo-analyzer.pem` (mode `0400`).
  - Target requirement: Must be copied to `~/.ssh/git-repo-analyzer.pem` with mode `0400` and removed from the project root workspace prior to provisioning.
  - Rule: `.gitignore` is not an equivalent security substitute for keeping private keys outside project repositories.
- [ ] **4. Remote State Backend Integrity**: Terraform backend configuration in `terraform/main.tf` verified intact:
  - Bucket: `git-repo-analyzer-terraform-state-2026`
  - Key: `git-repo-analyzer/terraform.tfstate`
  - Region: `ap-south-1`
  - Encryption: `encrypt = true`
  - State Locking: `use_lockfile = true`
  - *(Confirmed: S3 bucket exists and is empty; no remote state object is written until apply is executed. `terraform validate` confirms syntax only, not state initialization).*
- [ ] **5. AWS Promotional Credit Balance & Expiry Separation**:
  - Account operates under AWS Free Plan window expiring **March 12, 2027** (6-month evaluation period from account creation).
  - Promotional credit validity expires **September 12, 2027** (12-month validity window from grant date).
  - Credit Arithmetic Reconciliation (verified from November 18, 2026 billing snapshot):
    - Total Promotional Credits Issued: **$120.00** across two grants ($100.00 AWS Free Tier Promotion + $20.00 EC2 Launch Promotion).
    - Invoiced Promotional Credits Consumed: **$5.32** (drawn from the $100.00 grant).
    - Remaining Active Promotional Credit Balance: **$114.68** ($94.68 AWS Free Tier active + $20.00 EC2 Launch active).
    - Estimated Net Remaining Credit Balance: **$107.98** (reflecting $114.68 active balance minus $6.70 in estimated unbilled month-to-date usage from Cost Explorer).
    - Any billing projections or usage charges beyond this explicit snapshot are marked as unverified estimates.
  - Expiration dates verified as separate and distinct timelines.
- [ ] **6. Terraform Plan Inspection**: `terraform plan` output thoroughly reviewed to confirm exactly 3 EC2 instances, 3 security groups, and 50 GB total gp3 storage are created. Zero unintended resource replacements.
- [ ] **7. Session Cost Estimate Review**: On-demand fleet running rate reviewed (~$0.0773/hour across compute, storage, and 3 public IPs; ~$0.31 for a 4-hour demonstration session).
- [ ] **8. Teardown Preparedness**: Operator prepared to run `terraform destroy` immediately upon demonstration conclusion under ADR 011.
- [ ] **9. Explicit Owner Approval (Boundary B)**: Written authorization received from project owner prior to running `terraform apply`.

---

## 7. Ephemeral vs. Persistent Lifecycle & Data Management

Under **ADR 011**, all compute and host storage is ephemeral, designed for rapid demonstration and complete teardown:

| Category | Component / Data Item | Persistence Status | Storage Location & Retention Policy |
| :--- | :--- | :--- | :--- |
| **Persistent** | Codebase & Configurations | **Permanent** | Version-controlled in Git repository. |
| **Persistent** | Terraform Remote State | **Permanent** | S3 bucket `git-repo-analyzer-terraform-state-2026`. Never destroyed. |
| **Ephemeral** | EC2 Virtual Machines | **Destroyed** | Terminated on `terraform destroy`. |
| **Ephemeral** | EBS Root Volumes (50 GB) | **Destroyed** | Deleted on termination (`delete_on_termination = true`). |
| **Ephemeral** | Puppet CA Keys & Database | **Destroyed** | Destroyed with EC2 1. Reinitialized on next apply. |
| **Ephemeral** | Jenkins Jobs & Workspaces | **Destroyed** | Destroyed with EC2 3. Recreated on next apply. |
| **Ephemeral** | Docker Image Caches | **Destroyed** | Repulled from Docker Hub on next session. |
| **Ephemeral** | Nagios History & Metrics | **Destroyed** | Destroyed with EC2 2. |
| **Exportable**| Generated Analysis Reports | **Session-Bound** | Must be exported to local disk or Git prior to `terraform destroy`. |

---

## 8. Technical Status Classification: Detailed Verification Evidence

To ensure absolute documentation honesty, all technical claims are classified into explicit evidence tiers:

- **Official Documentation & Vendor Specification Verified**:
  - Official Puppet Platform 8 APT repository availability for Ubuntu 24.04 (`puppet8-release-noble.deb` at `https://apt.puppet.com`).
  - Puppet 8 CA JSON array schema (`puppetserver ca list --all --format json` returning array of objects with `name`, `state`, `fingerprint`).
  - Puppet agent exit code semantics with `--detailed-exitcodes` (0: clean, 2: changes applied, 1/4/6: error).
  - AWS Default VPC Internet Gateway routing behavior with public IPv4 allocation.
- **Source/Package Implementation Inspected**:
  - `terraform/` codebase: HCL modules, dynamic inventory template, directional security groups, gp3 EBS volumes.
  - `ansible/` codebase: `roles/common`, `roles/docker`, `roles/nginx`, `playbooks/site.yml`.
  - `analyze2.sh`: Parameter passing, zero-commit checks, non-interactive mode.
  - `Dockerfile` & `Jenkinsfile`: Cairo/Pango build stack, non-root execution parameters.
- **Executed Successfully in Local Test Environment**:
  - Phase 2 Docker container execution on active and zero-commit repositories (all tests exited with code 0).
  - Code validation: `terraform fmt -check`, `terraform validate`, and `git diff --check` passed cleanly with exit code 0.
  - *(Note: `terraform validate` verifies syntax and module configurations only; it does not connect to AWS or prove remote state initialization).*
- **Validated Against Live AWS Infrastructure**:
  - IAM caller identity (`arn:aws:iam::704475327786:user/terraform-admin`).
  - Persistent S3 state bucket existence and configuration (`git-repo-analyzer-terraform-state-2026`, AES256, versioning enabled).
  - Zero EC2 instances or security groups currently exist in AWS for this project.
  - *(Note: No EC2, Puppet, Jenkins, or Nagios live infrastructure has been validated because no instances have been provisioned).*
- **Not Yet Verified / Pending Live AWS Deployment**:
  - Live Puppet CA initialization and certificate signing on EC2 1.
  - Live Puppet Agent catalog application across instances.
  - Live out-of-band EC2 serial console fingerprint retrieval latency.
  - Live Nagios Core active monitoring over NRPE TCP 5666.
  - Live backend-to-Jenkins API job dispatch and artifact retrieval.
  - Actual T3 CPU credit consumption under prolonged demonstration workloads.
