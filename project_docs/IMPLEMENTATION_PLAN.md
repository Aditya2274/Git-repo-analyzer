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
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (54/54 Tests Passed; Service Lifecycle Corrected, Cryptographically Verified & Handover Protected)**. Live host application pending Boundary B.
     - **Corrective History & Audit Iteration**:
       - *Initial Implementation (`a6289d8`)*: Configured agent installation, certname configuration, and CSR submission, but left service daemon active (`state: started`, `enabled: true`), defaulted reachability to non-strict (`require_server_reachable: false`), and suppressed CSR CLI failure (`failed_when: false`), causing misleading "pending CA approval" notices on unreachable servers and risking background catalog application races.
       - *Audit Follow-up (`61f0bb8`)*: Enforced strict reachability (`require_server_reachable: true` by default), distinguished remote submission (`puppet ssl submit_request`, failing fast on `rc != 0`) from offline generation (`puppet ssl generate_request`), and stopped the daemon (`state: stopped`).
       - *Final Service Lifecycle Correction*: Independent review noted that a systemd-enabled service (`enabled: true`) can start automatically after a host reboot even if stopped, violating lifecycle gating. Checkpoint 4.4 defaults were updated to both `puppet_agent_service_state: "stopped"` and `puppet_agent_service_enabled: false`. Handlers strictly require both `state == 'started'` and `enabled == true`. The service remains disabled and stopped throughout Checkpoint 4.4.
       - *Lifecycle-Aware Handover Protection*: To prevent repeated executions of `site.yml` from stopping or disabling the agent post-handover, `service.yml` implements a cryptographic certificate-state guard. If a valid signed certificate is present, unexpired, matching the agent certname, and verified against the Puppet CA bundle, service enforcement is skipped to preserve Puppet's steady-state ownership, with an explicit override `puppet_agent_force_bootstrap: true` for manual operator recovery.
     - Implemented dedicated Ansible role `ansible/roles/puppet_agent/` with modular task structure: `preflight.yml`, `repository.yml`, `install.yml`, `config.yml`, `csr.yml`, `service.yml`, `defaults/main.yml`, and `handlers/main.yml`.
     - Preflight task validates target OS (`Ubuntu 24.04 LTS Noble`), inventory targeting (`app-server` on EC2 2, `cicd-server` on EC2 3), resolves `puppet-server` against expected private IP from inventory, and tests TCP 8140 reachability with actionable diagnostics. Strict mode defaults to `puppet_agent_require_server_reachable: true` (failing fast in live runs).
     - Repository task installs official `puppet8-release-noble.deb` and enforces APT priority pinning (`/etc/apt/preferences.d/puppetlabs.pref` pinning `origin apt.puppet.com` @ 900 > 500) to reject Ubuntu Universe's distro package. No Jammy fallback is needed or used (native Noble `puppet-agent` package published by vendor).
     - Installation task installs official `puppet-agent` package and validates binary executable path `/opt/puppetlabs/bin/puppet`.
     - Configuration task non-destructively manages `/etc/puppetlabs/puppet/puppet.conf` via `community.general.ini_file`: configures `server = puppet-server`, stable certnames (`app-server` on EC2 2, `cicd-server` on EC2 3), `runinterval = 30m`, preserves custom options, and ensures `autosign` is strictly absent.
     - CSR submission task implements controlled registration:
       - Preserves existing valid certificates and skips submission (zero key/cert regeneration).
       - Fails fast safely if existing certificate identity conflicts with inventory certname or is corrupted/mismatched.
       - Submits CSR via `/opt/puppetlabs/bin/puppet ssl submit_request --server puppet-server` when no certificate exists and server is reachable (failing fast on `rc != 0`).
       - Generates local CSR via `/opt/puppetlabs/bin/puppet ssl generate_request` in explicit offline mode without network transmission.
       - Verifies that local CSR exists and subject CN strictly matches expected certname (`app-server` or `cicd-server`).
       - Enforces strict security boundaries: zero autosigning, zero CA signing (signing belongs exclusively to Checkpoint 4.5), zero CA private key copying, zero key sharing between nodes, and zero destructive SSL removal.
     - Service task manages `puppet` systemd unit as both disabled and stopped (`enabled: false`, `state: "stopped"`), with handler guard requiring both `state == 'started'` and `enabled == true`, protected by a post-enrollment cryptographic certificate state guard.
     - Created test playbook `ansible/playbooks/test-puppet-agent.yml` and comprehensive fixture test suite `ansible/tests/test_puppet_agent_role.sh` (54/54 PASS). All project test suites pass (208/208 checks).
  5. **Checkpoint 4.5: Puppet CA Verification & Strict CSR Enrollment**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (45/45 Tests Passed; 9-Step Handover Orchestrated)**. Live host application pending Boundary B.
     - Implemented complete 9-step enrollment and handover workflow across `ansible/roles/puppet_server/`, `ansible/roles/puppet_agent/`, and `ansible/playbooks/enroll-puppet-agents.yml`:
       1. **Step 1 — Pre-Enrollment Connectivity Verification (`ansible/roles/puppet_agent/tasks/connectivity.yml`)**:
          - Probes TCP 8140 reachability from agent nodes to `puppet_server_host` using `ansible.builtin.wait_for`.
          - Configurable bounded timeout (`puppet_ca_connect_timeout: 10`).
          - Fails fast with clear, actionable diagnostic output if server is unreachable, halting before any CA operations.
       2. **Step 2 — Pending CSR Inspection (`ansible/roles/puppet_server/tasks/signing.yml`)**:
          - Executes `puppetserver ca list --all --format json` on Puppet Server CA.
          - Defensive JSON schema parsing supporting both Puppet 8 dictionary schemas (`certificate_requests`, `signed_certificates`) and sequence schemas (`[{"name": "...", "state": "requested"}]`).
          - Handles empty queues and query failures safely (`failed_when: ca_list_raw.rc != 0`).
       3. **Step 3 — Identity Allowlisting & Controlled Signing (`ansible/roles/puppet_server/tasks/signing.yml`)**:
          - Enforces strict allowlist: `puppet_ca_allowed_agents: ['app-server', 'cicd-server']`.
          - Security Check: Compares discovered pending CSRs against allowlist; immediately triggers `CRITICAL SECURITY ALERT` and halts execution if any unauthorized CSR identity is detected.
          - Completeness Check: Asserts all allowlisted agents have either pending CSRs or signed certificates (`missing_agents`); halts execution if an expected CSR is absent.
          - Signs approved CSRs individually: `/opt/puppetlabs/bin/puppetserver ca sign --certname {{ item }}`.
          - Idempotency: Skips nodes with certificates already signed on CA.
          - Zero `--all` or wildcard signing permitted.
          - Re-queries CA and verifies all allowlisted agents are confirmed signed.
       4. **Step 4 — Certificate Enrollment Verification (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Downloads signed certificate via `puppet ssl download_cert` if not yet present on local disk.
          - Verifies certificate enrollment and trust chain via `puppet ssl verify`.
          - Asserts local certificate exists at `/etc/puppetlabs/puppet/ssl/certs/<certname>.pem`.
          - Extracts certificate subject CN using OpenSSL and strictly asserts exact match with `puppet_agent_certname`. Verification failure halts immediately before catalog application.
       5. **Step 5 — Supervised Catalog Application (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Executes supervised catalog compilation and application: `timeout {{ puppet_catalog_timeout | default(300) }} /opt/puppetlabs/bin/puppet agent -t --detailed-exitcodes`.
          - Preserves full stdout, stderr, and detailed return code in `puppet_catalog_run` (`failed_when: false`).
       6. **Step 6 — Strict Exit-Code Validation (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Evaluates detailed return codes:
            - `0`: Clean execution, no changes required (ACCEPTED).
            - `2`: Clean execution, resource changes successfully applied (ACCEPTED).
            - `1`: General failure / compilation error (STRICTLY REJECTED).
            - `4`: Resource transaction failures (STRICTLY REJECTED).
            - `6`: Changes applied with transaction failures (STRICTLY REJECTED).
            - `124`: Bounded timeout exceeded (STRICTLY REJECTED).
            - Any unexpected code: STRICTLY REJECTED.
       7. **Step 7 — Catalog Result Verification & Reporting (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Formally logs catalog results, distinguishing clean idempotent runs (code 0) from clean resource mutations (code 2).
       8. **Step 8 — Explicit Service Activation Gate (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Systemd service defaults in `roles/puppet_agent/defaults/main.yml` remain `puppet_agent_service_enabled: false` and `puppet_agent_service_state: "stopped"` per Checkpoint 4.4 invariants.
          - Explicitly transitions service to `enabled: true` and `state: started` ONLY when `puppet_catalog_run.rc in [0, 2]`.
          - Signing alone or certificate verification alone NEVER activates or starts the daemon.
       9. **Step 9 — Active Daemon Verification (`ansible/roles/puppet_agent/tasks/handover.yml`)**:
          - Verifies daemon active status: `systemctl is-active puppet` strictly returns `active`.
          - Verifies daemon boot-persistence status: `systemctl is-enabled puppet` strictly returns `enabled`.
          - Reports successful handover completion for continuous autonomous configuration management.
     - Central Orchestration Playbook (`ansible/playbooks/enroll-puppet-agents.yml`):
       - Play 1 (`hosts: puppet_agents`): Pre-enrollment connectivity check to Puppet Server (Step 1).
       - Play 2 (`hosts: puppet_server`): CA inspection and controlled allowlisted signing (Steps 2 & 3).
       - Play 3 (`hosts: puppet_agents`): Certificate verification, supervised catalog run, service activation, and daemon verification (Steps 4–9).
     - Created comprehensive fixture test suite `ansible/tests/test_puppet_enrollment.sh` (45/45 PASS). Full regression suite: 131/131 checks pass across all 6 project test suites.
  6. **Checkpoint 4.6: Docker Engine & Compose Bootstrap (EC2 3)**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (30/30 Tests Passed; 161/161 Full Suite Regression)**. Live host application pending Boundary B.
     - Implemented modular, idempotent, and secure Ansible role `ansible/roles/docker/`:
       - **Targeting & Preflight (`tasks/preflight.yml`)**: Enforces strict dual-condition targeting: requires both canonical inventory hostname (`cicd-server` / EC2 3) and inventory group (`cicd`) via disjunctive fail logic (`(inventory_hostname != target_host) or (target_group not in group_names)`), halting immediately if executed against `puppet-server` or `app-server`, or if either condition is not met. Validates Ubuntu 24.04 LTS (Noble) target and 64-bit CPU architecture (`amd64`/`x86_64`).
       - **Repository & Keyring Configuration (`tasks/repository.yml`)**: Installs prerequisites (`ca-certificates`, `curl`), ensures `/etc/apt/keyrings` exists (mode `0755`), downloads official Docker ASCII armor GPG key to `/etc/apt/keyrings/docker.asc` (mode `0644`), and configures official Docker APT repository via modern `signed-by` syntax in `/etc/apt/sources.list.d/docker.list` (zero deprecated `apt-key` usage).
       - **Package Installation (`tasks/install.yml`)**: Declares official Docker Engine components: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin` with `state: present` (avoiding breaking upgrades). Excludes legacy standalone `docker-compose`.
       - **Daemon Configuration & Security (`tasks/config.yml`)**: Deploys `/etc/docker/daemon.json` configuring `log-driver: json-file` with bounded log rotation (`max-size: 10m`, `max-file: 3`) to prevent unbounded disk consumption on a 20 GB EBS volume. Enforces security assertion strictly prohibiting unauthenticated TCP daemon endpoints (`tcp://`), binding exclusively to the local UNIX socket (`unix:///var/run/docker.sock`).
       - **Service Lifecycle Management (`tasks/service.yml`, `handlers/main.yml`)**: Configures systemd management for both `containerd` and `docker` units (`state: started`, `enabled: true`). Implements guarded restart handlers (`Restart Docker daemon`, `Restart containerd`).
       - **User Permissions & Group Security (`tasks/users.yml`)**: Ensures `docker` group exists; adds authorized users (`ubuntu` from `group_vars/cicd.yml`) with `append: true` to preserve existing group memberships; enforces strict security check preventing premature addition of `jenkins` user in Phase 4 (deferred strictly to Phase 7 per ADR 007 and `AGENTS.md`).
       - **Verification Tasks (`tasks/verify.yml`)**: Verifies presence of Docker CLI and Docker Compose plugin (`docker compose version`), checks active/enabled daemon status, and outputs summary diagnostics.
     - Updated test playbook `ansible/playbooks/test-docker.yml` to target canonical `hosts: cicd` with `become: true`.
     - Authored isolated fixture test suite `ansible/tests/test_docker_role.sh` (30/30 PASS).
     - Full project regression test baseline: 161/161 checks passing across all 7 test suites.
  7. **Checkpoint 4.7: NGINX Bootstrap Baseline (EC2 2)**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (30/30 Tests Passed; 208/208 Full Suite Regression)**. Live host application pending Boundary B.
     - Implemented modular, idempotent, and secure Ansible role `ansible/roles/nginx/`:
       - **Targeting & Preflight (`tasks/preflight.yml`)**: Enforces strict dual-condition targeting: requires both canonical inventory hostname (`app-server` / EC2 2) and inventory group (`application`) via disjunctive fail logic (`(inventory_hostname != target_host) or (target_group not in group_names)`), halting immediately if executed against `puppet-server` or `cicd-server`. Validates Ubuntu 24.04 LTS (Noble) target and supported 64-bit CPU architecture (`amd64`/`x86_64`/`arm64`).
       - **Package Installation (`tasks/install.yml`)**: Declares official Ubuntu distribution package `nginx` with `state: present` and bounded cache validity (`cache_valid_time: 3600`) via `ansible.builtin.apt`. Strictly excludes arbitrary external repositories or version pinning.
       - **Baseline Configuration & Security Controls (`tasks/config.yml`)**: Ensures `/etc/nginx`, `conf.d`, `sites-available`, and `sites-enabled` directories exist with mode `0755` (`root:root`). Deploys baseline security configuration snippet `/etc/nginx/conf.d/security.conf` (mode `0644`) enforcing `server_tokens off;` to prevent server version disclosure. Deploys baseline default virtual host `/etc/nginx/sites-available/default` (mode `0644`) listening on port 80 default_server, disabling directory listings (`autoindex off;`), and exposing a baseline `/healthz` endpoint returning HTTP 200. Ensures `sites-enabled/default` symlink exists and removes any premature application sites (`sites-enabled/git-repo-analyzer` absent). Pre-validates configuration syntax via `nginx -t` with `changed_when: false` before notifying handlers.
       - **Service Lifecycle Management (`tasks/service.yml`, `handlers/main.yml`)**: Manages `nginx` systemd service (`state: started`, `enabled: true`). Implements guarded `Reload NGINX` (state: `reloaded`) and `Restart NGINX` (state: `restarted`) handlers guarded on `nginx_service_state == 'started'`.
       - **Verification Tasks (`tasks/verify.yml`)**: Validates `/usr/sbin/nginx` binary existence, checks `nginx -v` version, executes `nginx -t` syntax test, and outputs summary diagnostics with `changed_when: false`.
     - Updated test playbook `ansible/playbooks/test-nginx.yml` targeting canonical `hosts: application` with `become: true`.
     - Authored comprehensive fixture test suite `ansible/tests/test_nginx_role.sh` (30/30 PASS), including reversion sensitivity checks confirming detection of defective OR-permitting logic.
     - Full project regression test baseline: 208/208 checks passing across all 8 test suites.
   8. **Checkpoint 4.8: Phase 4 Local Consolidation & Boundary B Pre-flight Verification**:
     - *Status*: **Complete at Local Implementation & Fixture Validation Level (208/208 Full Suite Regression, 7/7 Playbooks Syntax Clean, Terraform Format Clean)**. Ready for separately authorized Boundary B live deployment.
     - Refactored master fleet orchestration playbook [`ansible/playbooks/site.yml`](file:///home/aditya-2274/Git-repo-analyzer/ansible/playbooks/site.yml) to execute modular roles across canonical inventory groups (`hosts: all` $\to$ `common`, `hosts: puppet_server` $\to$ `puppet_server`, `hosts: puppet_agents` $\to$ `puppet_agent`, `hosts: cicd` $\to$ `docker`, `hosts: application` $\to$ `nginx`), enforcing strict target isolation and eliminating legacy `webservers` warnings.
     - Cleaned up obsolete untracked learning exercises (`conditions.yml`, `handler-demo.yml`, `install-packages.yml`, `system-info.yml`, `template-demo.yml`, `app.conf.j2`, `demo.txt`), leaving exactly 7 playbooks (2 authoritative operational playbooks: `site.yml`, `enroll-puppet-agents.yml`; 5 diagnostic role runners: `test-common.yml`, `test-puppet-server.yml`, `test-puppet-agent.yml`, `test-docker.yml`, `test-nginx.yml`) that all pass `ansible-playbook --syntax-check` with zero warnings.
     - Verified all 8 Phase 4 regression test suites pass with 100% success (208/208 checks).
     - Verified Terraform configuration formatting with `terraform fmt -check` (clean, exit 0).
     - Authored comprehensive Boundary B deployment runbook and readiness checklist covering prerequisite verification, Terraform provisioning, dynamic inventory sync, host-key verification, Ansible bootstrap sequence, service verification, and teardown procedures.
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
- **Architectural Reference:** The complete architectural specification, comparative evaluation (Ansible-only vs. Puppet-only), lifecycle interaction diagrams, and resource ownership boundaries are codified in [`project_docs/ANSIBLE_AND_PUPPET_ARCHITECTURE.md`](file:///home/aditya-2274/Git-repo-analyzer/project_docs/ANSIBLE_AND_PUPPET_ARCHITECTURE.md).
- **Prerequisites:** Phase 4 completion (Puppet agents communicating with Puppet Server).
- **Checkpoints & Execution Roadmap:**
  1. **Checkpoint 5A.1: Puppet Module Architecture & Manifest Structure**:
     - *Status*: **Complete at Local Implementation & Verification Level (15/15 Tests Passed)**.
     - Established clean module hierarchy: `puppet/manifests/site.pp`, `puppet/hiera.yaml`, `puppet/hieradata/common.yaml`, `puppet/modules/common/`, `puppet/modules/nrpe/`, and `puppet/modules/nagios/`.
     - Defined authoritative node classification in `site.pp` (`puppet-server`, `app-server`, `cicd-server`, `default`) with explicit arrow chaining (`->`) to enforce dependency order and prevent circular dependencies.
     - Declared global `Exec` default path in `site.pp`.
     - Configured Puppet Hiera v5 structure and parameters in `hieradata/common.yaml`.
     - Verified all manifests via `puppet parser validate` with 100% syntax compliance.
     - Authored and executed dedicated test suite `puppet/tests/test_puppet_architecture.sh` (15/15 checks passed).
  2. **Checkpoint 5A.2: Common Module**:
     - *Status*: **Complete at Local Implementation & Verification Level (14/14 Tests Passed)**.
     - Responsibilities: baseline system packages (`curl`, `wget`, `git`, `htop`, `unzip`, `tar`, `jq`, `ca-certificates`), timezone configuration (`/etc/timezone` and `/etc/localtime` symlink), and steady-state Puppet Agent service management (`service { 'puppet': ensure => running, enable => true }`) post-enrollment.
     - Enforces explicit linear dependency ordering: `Package[$packages] -> File['/etc/timezone'] -> File['/etc/localtime'] -> Service[$puppet_agent_service]`.
     - Preserves isolation: manages exclusively `puppet.service` without declaring or interfering with `puppetserver.service` on EC2 1.
     - Supports `manage_puppet_agent` toggle for maintenance or testing.
     - Validated via `puppet apply --noop`, Hiera v5 parameter binding, fleet-wide `site.pp` compilation across all three nodes, and dedicated test suite `puppet/tests/test_common_module.sh` (14/14 checks passed).
  3. **Checkpoint 5A.3: NRPE Module**:
     - *Status*: **Complete at Local Implementation & Verification Level (20/20 Tests Passed)**.
     - Responsibilities: `nrpe::server` on monitored targets (`puppet-server` and `cicd-server`) managing packages (`nagios-nrpe-server`, `monitoring-plugins-basic`), directories (`/etc/nagios`, `/etc/nagios/nrpe.d`, `/usr/lib/nagios/plugins`), custom read-only check scripts (`check_jenkins.sh`, `check_docker.sh`, `check_puppetserver.sh`) ordered strictly `before => Service[$service_name]`, authoritative template (`nrpe.cfg.erb`) with strict `allowed_hosts` (restricted strictly to loopback and `app-server`), security posture (`dont_blame_nrpe=0`, zero argument injection), pre-restart configuration validator (`validate_cmd` with awk), and systemd service `nagios-nrpe-server` requiring both plugin and daemon packages plus config (with optional `service_ensure`/`service_enable` supporting stopped-service refresh safety); `nrpe::client` on monitoring host (`app-server`) managing client plugin package (`nagios-nrpe-plugin`).
     - Validated via `puppet parser validate`, local check script behavioral tests, AST typing, ERB rendering, awk `validate_cmd` logic, individual class compilation (`puppet apply --noop`), JSON catalog DAG inspection (`puppet catalog find`), Hiera v5 parameter binding, master `site.pp` fleet compilation across all three nodes, and dedicated test suite `puppet/tests/test_nrpe_module.sh` (20/20 checks passed).
  4. **Checkpoint 5A.4: Nagios Module (Hardened)**:
     - *Status*: **Complete at Local Implementation & Verification Level (26/26 Tests Passed)**.
     - Responsibilities:
       - `nagios::install_guard`: Implements a narrowly scoped, temporary `/usr/sbin/policy-rc.d` lifecycle around Ubuntu 24.04 package installation (`nagios4`, `monitoring-plugins-basic`, `apache2`, `apache2-utils`) so Debian/APT `postinst` maintainer scripts (`invoke-rc.d` / `deb-systemd-invoke`) cannot prematurely start `nagios4.service` or `apache2.service` (which would fail on port 80 against NGINX or run unconfigured) before Puppet deploys and validates configuration.
         - No existing policy: atomically creates temporary guard (`0755`) scoped strictly to `nagios4` and `apache2` while active Puppet PID (`/run/puppet-nagios-pkg-install.pid`) is live; all unrelated daemons return exit `0`.
         - Existing Puppet-marked policy: checks recorded Puppet PID lifecycle (fails safely if a concurrent live Puppet process holds it; refreshes stale PID on recovery).
         - Existing administrator-managed policy: preserves byte-for-byte unmodified (never overwrites, deletes, or executes untrusted administrator-owned code as root) and fails closed before package installation with operator diagnostics requiring the administrator to inspect and resolve/remove the pre-existing policy first.
         - If package installation fails and Puppet exits, the stale PID immediately fails open (exit `0`) so the machine is never blocked, and any subsequent run cleans up the marked file safely.
         - Removed automatically after packages complete; 100% no-op idempotent once packages are installed.
       - `nagios::server`: Installs Ubuntu 24.04 packages (`nagios4`, `monitoring-plugins-basic` without duplicate `nagios-nrpe-plugin`), manages `/etc/nagios4` hierarchy, authoritative templates (`nagios.cfg.erb`, `cgi.cfg.erb`, `resource.cfg.erb` with `$USER1$=/usr/lib/nagios/plugins`), refresh and pre-start configuration validators (`nagios4_configtest` and `nagios4_configtest_before_start` running `/usr/sbin/nagios4 -v /etc/nagios4/nagios.cfg`), and systemd service `nagios4.service`.
       - `nagios::objects`: Manages `/etc/nagios4/conf.d` directory and object definition templates:
         - `hosts.cfg`: Defines all three fleet nodes (`puppet-server`, `app-server` on `127.0.0.1`, `cicd-server`) and `generic-host` template.
         - `commands.cfg`: Defines `check-host-alive`, `check_nrpe` (`$USER1$/check_nrpe -H $HOSTADDRESS$ -c $ARG1$ -t 30` with zero arbitrary `-a` arguments), local checks (`check_local_disk`, `check_local_load`, `check_local_procs`, `check_local_users`, `check_http_port`), and demonstration notification commands.
         - `services.cfg`: Accurately maps node-specific checks: `puppet-server` receives `NRPE Connectivity` and `Puppet Server Service` (strictly zero Jenkins/Docker checks); `cicd-server` receives `NRPE Connectivity`, `Jenkins Service`, and `Docker Service` (strictly zero Puppet Server check); `app-server` receives local disk, CPU load, process count, and NGINX HTTP checks.
         - `contacts.cfg`: Defines administrator contact `nagiosadmin` and contact group `admins`.
         - `timeperiods.cfg`: Defines `24x7`, `workhours`, and `none` time periods.
       - `nagios::web`: Installs `apache2` and `apache2-utils`, manages `/etc/apache2/ports.conf` (strictly loopback `127.0.0.1:8080`, zero public 80/443 exposure), `/etc/apache2/sites-available/nagios.conf` virtual host with HTTP Basic Authentication, disables `000-default.conf`, deploys `/etc/nagios4/htpasswd.users` with restrictive permissions (`0640`, `root:www-data`), refresh and pre-start validators (`apache2_configtest` and `apache2_configtest_before_start` running `/usr/sbin/apache2ctl configtest`), and manages systemd service `apache2`.
       - Fail-closed credential handling: `nagios::web::enforce_production_secret` defaults to `true`, and `nagios::web::admin_password_hash` defaults to `undef` (removed demo placeholder from `common.yaml`). Absent, empty, malformed, colon-containing, or known-placeholder credentials fail catalog compilation by default. Before live deployment, operators must generate a bcrypt hash interactively (`htpasswd -B -C 12 -n nagiosadmin` — never pass plaintext passwords via `-b`) and supply only the hash via protected node-specific Hiera (`puppet/hieradata/nodes/app-server.yaml`) or deployment override. Test/dev mode requires explicit override via test fixtures.
       - Strict 9-step ordering: Package suppression -> packages -> suppression cleanup -> Nagios dirs/configs/objects -> Apache configs & htpasswd -> Nagios & Apache validations -> service start/enable.
       - Node targeting: Class `nagios` is strictly restricted to `app-server`. Attempted inclusion on other nodes fails compilation fast.
     - Validated via `puppet parser validate`, ERB `sh -n`, `--graph` DAG reachability verification, master `site.pp` compilation across all three nodes (`puppet apply --noop` with fail-closed negative test + test-only Hiera fixture), sandboxed `/tmp` behavioral runs of `nagios::install_guard` (absent policy, unexecuted admin policy fail-closed, Puppet guard lifecycle, failed-install recovery) and validation failure blocking, and dedicated test suite `puppet/tests/test_nagios_module.sh` (26/26 checks passed). Remaining limitation before live deployment: real operator hash required in Hiera and live Ubuntu package/systemd execution awaits Phase 8 EC2 provisioning under Approval Boundary B.
  5. **Checkpoint 5A.5: Puppet Catalog Compilation, Dependency Ordering, Node Targeting & Convergence Validation**:
     - *Status*: **Complete at Local Catalog, DAG & Fixture Validation Level (8/8 Integrated Checks Passed; 83/83 Combined Phase 5A Suite; 208/208 Phase 4 Regression)**.
     - Scope & Findings:
       - Compiled full JSON catalogs (`puppet catalog find ... --terminus=compiler --render-as=json`) and `--graph` relationship graphs (`expanded_relationships.dot`) for `puppet-server`, `app-server` (isolated test-only Hiera credential fixture), `cicd-server`, and `default`/unrecognized certnames.
       - Closed concrete NRPE DAG ordering gap in `nrpe::server`: added `before => Service[$service_name]` on targeted check scripts (`check_puppetserver.sh`, `check_jenkins.sh`, `check_docker.sh`), added `Package[$plugin_packages]` to `Service[$service_name]` `require`, and added optional `service_ensure`/`service_enable` matching `common`/`nagios` (preserving Puppet `Service#refresh` skip behavior when stopped).
       - Audited test wording across Phase 5A suites so repeated catalog compilation checks explicitly distinguish **catalog-level determinism / cycle-free compilation** from sandboxed fixture convergence (`--detailed-exitcodes` exit `2 -> 0`) and live EC2 convergence (deferred to Approval Boundary B).
     - Verified end-to-end Nagios `services.cfg` $\leftrightarrow$ NRPE `nrpe.cfg` command parity, strict cross-node resource isolation, cycle-free DAG DFS reachability across `common`, `nrpe`, and `nagios`, and fail-closed safety via `puppet/tests/test_phase5a_convergence.sh` (8/8 checks passed).
- **Puppet Agent Ownership Transition Sequence**:
     - **Step 1 (Ansible Bootstrap)**: Ansible installs `puppet-agent` (8.10.x), configures `puppet.conf` with certname and server, and enforces `puppet_agent_service_enabled: false` and `puppet_agent_service_state: stopped` (preventing premature connection).
     - **Step 2 (Ansible Supervised Enrollment)**: Ansible verifies TCP 8140 reachability, submits agent CSRs, signs certificates on EC2 1 with strict allowlisting, executes initial catalog run (`puppet agent -t --detailed-exitcodes`), verifies exit codes 0 or 2, and only then enables and starts `puppet.service`.
     - **Step 3 (Puppet Steady-State Ownership)**: In Phase 5A, Puppet's `common` module assumes exclusive steady-state desired-state ownership of `/etc/puppetlabs/puppet/puppet.conf` (`runinterval = 30m`) and `service { 'puppet': ensure => running, enable => true }`.
     - **Step 4 (Ansible Handover)**: Ansible permanently relinquishes management of `puppet.conf` and `puppet.service`. Ansible owns zero agent configuration resources post-enrollment.
  4. **NRPE Daemon Deployment via Puppet**:
     - Deploy Puppet module `nrpe` targeting EC2 1 and EC2 3.
     - Install verified packages: `nagios-nrpe-server` (4.1.0) and `monitoring-plugins-basic` (2.3.5) providing plugin executables under `/usr/lib/nagios/plugins/`.
     - Configure `/etc/nagios/nrpe.cfg`: restrict `allowed_hosts` strictly to `app-server` private IP.
     - Deploy base NRPE check definitions pointing to verified executables: `/usr/lib/nagios/plugins/check_disk`, `/usr/lib/nagios/plugins/check_load`, `/usr/lib/nagios/plugins/check_procs`.
     - Start and enable systemd service `nagios-nrpe-server.service` (verified service name in Ubuntu 24.04).
  5. **Nagios Core Prerequisites Deployment (EC2 2)**:
     - Install verified packages: `apache2`, `apache2-utils`, `monitoring-plugins-basic`.
     - Built-in Apache Authentication: Use Apache's built-in `mod_auth_basic` and `mod_authn_file` modules provided by `apache2` (the legacy package `libapache2-mod-auth-basic` does not exist in Ubuntu 24.04).
     - Configure Apache loopback virtual host binding strictly to `127.0.0.1:8080` (accessible exclusively via operator SSH tunnel `ssh -L 8080:127.0.0.1:8080`).
     - Configure HTTP Basic Authentication file (`/etc/nagios/htpasswd.users`) using `htpasswd` for `nagiosadmin`.
  6. **Six-Tier Validation & Idempotency Testing Design (Local Testing Under Approval Boundary A)**:
     - *Tier 1: Manifest Syntax Validation*: `puppet parser validate` across `site.pp` and all manifests (grammar/syntax checks only; does not verify catalog compilation).
     - *Tier 2: Lint Validation*: `puppet-lint --fail-on-warnings` validating Puppet style guidelines and indentation.
     - *Tier 3: Catalog Compilation Validation*: Automated mock catalog compilation verifying variable resolution, resource uniqueness, and parameter types without syntax-alone assumptions.
     - *Tier 4: Node-Specific Resource Targeting*: Distinct validation ensuring `puppet-server`, `app-server`, and `cicd-server` node blocks compile only their authorized modules.
     - *Tier 5: Dependency Ordering (DAG & Cycle Detection)*: Validation of `Package -> File ~> Service` chains and relationship metaparameters (`before`, `require`, `notify`, `subscribe`) to guarantee zero circular dependency cycles.
     - *Tier 6: Idempotency Testing & Execution Hierarchy*:
       - **Level 1 — Static Fixture-Based Idempotency Tests**: Code analysis verifying declarative resource states (`ensure => present`, `ensure => running`) and absence of unconditioned `exec` resources.
       - **Level 2 — Puppet Catalog Compilation Tests**: AST and dependency graph verification with mock node facts, proving the catalog compiles deterministically.
       - **Level 3 — Actual Local Catalog Application**: Applying compiled catalogs against local test fixtures/targets and verifying detailed exit code `2` (clean changes successfully applied).
       - **Level 4 — Repeated Catalog Application (Demonstrated Idempotency)**: Executing a consecutive catalog application against the converged state and verifying detailed exit code `0` (clean, zero changes applied, zero failures).
       > [!IMPORTANT]
       > **Strict Idempotency Claim Policy**: Actual convergence or idempotency must never be claimed merely because parser validation passes or catalogs compile. True idempotency is only claimed after Level 4 repeated catalog execution has been performed and verified with exit code 0.
- **Completion Criteria:**
  - Puppet catalog compiles cleanly and enforces base desired state on all nodes.
  - NRPE daemon configuration verified for EC2 1 and EC2 3, strictly accepting queries from EC2 2.
  - Apache loopback configured for EC2 2 on port 8080 with basic authentication.
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
- **Objective:** Author and apply Puppet manifests to deploy the Node.js 24 LTS runtime, backend systemd service unit, NGINX virtual hosts, and environment configurations on EC2 2 based on the finalized contracts from Phase 6.
- **Prerequisites:** Phase 6 completion (application artifacts and contracts verified).
- **Subtasks:**
  1. **Deploy Node.js Runtime via Puppet (`modules/application/manifests/nodejs.pp`)**:
     - Deploy signed NodeSource Node.js 24 LTS repository (`node_24.x` / `nodistro`) on EC2 2; install `nodejs` (providing `/usr/bin/node`).
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
  - Node.js 24 LTS active on EC2 2.
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
- [ ] **6. Terraform Planning & Five-Stage Provisioning Approval**: Follow the structured five-stage provisioning workflow codified in Stage 1 of the Boundary B runbook: (1) Identity verification, (2) terraform init / validate, (3) terraform plan -var="allowed_ssh_cidr=$(curl -s https://checkip.amazonaws.com)/32" -out=tfplan, (4) human inspection and explicit approval of planned resources (exactly 3 EC2 instances, 3 security groups, 50 GB gp3 storage), and (5) terraform apply tfplan without -auto-approve. Zero unintended resource replacements.
- [ ] **7. Session Cost Estimate Review**: On-demand fleet running rate reviewed (~$0.0773/hour across compute, storage, and 3 public IPs; ~$0.31 for a 4-hour demonstration session).
- [ ] **8. Teardown Preparedness & Retained Cost Awareness**: Operator prepared to run `terraform destroy` without `-auto-approve` immediately upon demonstration conclusion under ADR 011. Acknowledged that while `terraform destroy` terminates all 3 EC2 instances, attached EBS volumes, and public IPv4 allocations (eliminating the estimated active fleet running cost of approximately $0.0773/hour), actual AWS account charges may remain: the persistent S3 remote state bucket `git-repo-analyzer-terraform-state-2026` is a permanently retained resource that survives teardown and must never be deleted, replaced, or modified. Any external account-level resources or historical usage also remain subject to standard billing.
- [ ] **9. Explicit Owner Approval & Partial Failure Halt Protocol (Boundary B)**: Written authorization received from project owner prior to running `terraform apply tfplan` (strictly without `-auto-approve`). Approval for Boundary A (Implementation) does not imply approval for Boundary B (AWS Provisioning). If a partial provisioning failure occurs: halt execution immediately, preserve Terraform state in S3, inspect and report partially created resources (`terraform state list`), do NOT automatically destroy resources, and require separate explicit operator authorization before any cleanup or teardown.

---

## 7. Authoritative Boundary B Deployment Runbook

> [!CAUTION]
> **Approval Boundary B Policy**: The commands in this runbook interact with live AWS infrastructure and create billable cloud resources. **DO NOT execute any step in this runbook without separate, explicit user authorization.**

### Execution Sequence Architecture

```text
                                  [ Approval Boundary B Entry ]
                                                │
                                    (Explicit User Approval)
                                                │
                                                ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│ Stage 1: Terraform Infrastructure Provisioning & Approval                                     │
│   1. Identity Verification ──► 2. terraform init / validate ──► 3. terraform plan -out=tfplan │
│   ──► 4. Human Review & Explicit Approval ──► 5. terraform apply tfplan (No Auto-Approve)     │
└───────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                │
                                                ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│ Stage 2: Inventory & Cryptographic SSH Trust                                                  │
│   6. bash sync_terraform_inventory.sh ──► 7. bash verify_ssh_host_keys.sh (Strict Fingerprints)   │
└───────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                │
                                                ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│ Stage 3: Authoritative 2-Playbook Ansible Bootstrap & Puppet Handover                         │
│   8. Master Fleet Bootstrap (site.yml: common, puppet_server, puppet_agent, docker, nginx)   │
│                                                │                                              │
│   9. Controlled CA Enrollment Playbook (enroll-puppet-agents.yml: 9-step supervised handover) │
└───────────────────────────────────────────────┬───────────────────────────────────────────────┘
                                                │
                                                ▼
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│ Stage 4: Live Verification, Demonstration & Teardown Gate                                     │
│   10. Fleet Connectivity & Health Check ──► 11. Export Run Logs ──► 12. Demonstration Session │
│   ──► 13. Pre-Teardown Artifact Export ──► 14. Explicit Teardown Approval                     │
│   ──► 15. terraform destroy (Retains Permanent S3 State Backend)                              │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Step 1: Pre-Deployment Authorization & Session Verification
- **Purpose**: Ensure explicit human authorization and active session awareness before provisioning billable resources.
- **Procedure**: Request operator confirmation. Verify AWS CLI caller identity:
  ```bash
  aws sts get-caller-identity
  ```
- **Expected Result**: Valid AWS Account ID and ARN (`arn:aws:iam::704475327786:user/terraform-admin`) returned.
- **Failure Condition**: Missing or expired AWS credentials $\to$ Halt immediately.

#### Step 2: Terraform Initialization & Configuration Validation
- **Purpose**: Verify backend connectivity and validate configuration syntax without modifying state.
- **Command**:
  ```bash
  cd terraform && terraform init && terraform validate && terraform fmt -check
  ```
- **Expected Result**: `Success! The configuration is valid.` Backend initialized with S3 state bucket.
- **Failure Condition**: Validation or backend error $\to$ Correct syntax/connectivity before proceeding.

#### Step 3: Terraform Planning & Human Inspection
- **Purpose**: Generate a deterministic execution plan with the operator's public `/32` IP for security group ingress.
- **Command**:
  ```bash
  cd terraform
  terraform plan -var="allowed_ssh_cidr=$(curl -s https://checkip.amazonaws.com)/32" -out=tfplan
  ```
- **Expected Result**: Plan output shows exactly 3 instances (`puppet-server`, `app-server`, `cicd-server`), 3 security groups, and 50 GB gp3 storage to create; 0 to change; 0 to destroy.
- **Human Inspection Gate**: Operator verifies:
  1. Operator public IP `/32` matches intended workstation.
  2. Exactly 3 EC2 instances created in public subnets of the Default VPC.
  3. Total EBS storage allocated equals exactly 50 GB (15 GB + 15 GB + 20 GB).
  4. Security group ingress rules strictly restrict SSH (22) to operator `/32`, HTTP/HTTPS (80/443) exclusively to EC2 2, and internal ports (8140, 8080, 5666) to appropriate security groups.
  5. Zero unintended resource destructions or replacements.

#### Step 4: Explicit Provisioning Approval Gate
- **Purpose**: Enforce the human-in-the-loop cost governance gate before applying changes.
- **Procedure**: Operator reviews the plan output and estimated running costs (~$0.0773/hour across fleet) and grants explicit authorization.
- **Failure Condition**: Operator denies authorization $\to$ Abort; discard `tfplan`.

#### Step 5: Infrastructure Provisioning (`terraform apply`)
- **Purpose**: Provision the approved 3-node fleet using the inspected execution plan without auto-approval bypass.
- **Command**:
  ```bash
  cd terraform && terraform apply tfplan
  ```
- **Expected Result**: Exactly 3 instances created with public IPv4 and private IPs. State saved to remote S3 backend.
- **Failure Condition & Strict Halt Protocol**:
  - Quota exhaustion, subnet collision, or AWS API error $\to$ **HALT IMMEDIATELY**.
  - **Do NOT automatically execute `terraform destroy`**. Automatic destruction violates the teardown approval gate (Step 14).
  - Preserve Terraform state intact in the S3 remote backend.
  - Inspect and report partially created resources via `terraform state list` and `terraform show`.
  - Require separate, explicit operator authorization before any cleanup, remediation, or destruction commands are executed.

#### Step 6: Dynamic Inventory Generation
- **Purpose**: Ingest live EC2 public and private IP addresses from Terraform state into Ansible inventory.
- **Command**:
  ```bash
  bash ansible/scripts/sync_terraform_inventory.sh
  ```
- **Expected Result**: [`ansible/inventory/hosts.ini`](file:///home/aditya-2274/Git-repo-analyzer/ansible/inventory/hosts.ini) atomically updated with live IP addresses; validated with `ansible-inventory --list`.
- **Failure Condition**: Empty or malformed Terraform output $\to$ Baseline inventory preserved; script aborts cleanly.

#### Step 7: Cryptographic SSH Host-Key Verification
- **Purpose**: Establish cryptographic SSH trust against EC2 console fingerprints, mitigating MITM risks without blind TOFU.
- **Command**:
  ```bash
  bash ansible/scripts/verify_ssh_host_keys.sh
  ```
- **Expected Result**: Host keys verified against EC2 system console output and recorded into [`ansible/known_hosts`](file:///home/aditya-2274/Git-repo-analyzer/ansible/known_hosts) (mode `0600`).
- **Failure Condition**: Console output delayed $\to$ Automatic bounded retry (up to 360s); mismatch triggers immediate MITM alert and aborts.

#### Step 8: Master Fleet Bootstrap (`ansible/playbooks/site.yml`)
- **Purpose**: Execute canonical master orchestration playbook across the 3-node fleet in strict dependency order:
  - Play 1 (`hosts: all`): Apply common baseline (APT record locks, dynamic `/etc/hosts` private DNS, swapfiles).
  - Play 2 (`hosts: puppet_server`): Bootstrap Puppet Server 8, tune JVM heap (`-Xms1g -Xmx1g`), initialize CA (State A), start service on TCP 8140.
  - Play 3 (`hosts: puppet_agents`): Install Puppet Agent 8 on EC2 2 & 3, set `server = puppet-server`, submit initial CSRs, and enforce gated stopped/disabled service state per ADR 012.
  - Play 4 (`hosts: cicd`): Bootstrap Docker Engine and Compose plugin on EC2 3, configure log rotation (`10m`/`3`), restrict daemon to local UNIX socket, add `ubuntu` user to `docker` group.
  - Play 5 (`hosts: application`): Bootstrap NGINX on EC2 2, configure baseline security (`server_tokens off;`), deploy default port 80 virtual host with `/healthz`, and pre-validate syntax via `nginx -t`.
- **Command**:
  ```bash
  ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/site.yml
  ```
- **Operational Execution Note**:
  - `site.yml` is the **authoritative master orchestration playbook** for live deployment.
  - The individual playbooks (`test-common.yml`, `test-puppet-server.yml`, `test-puppet-agent.yml`, `test-docker.yml`, `test-nginx.yml`) were authored during development for isolated component testing. Their `test-` naming reflects their initial test harness origin, but they are retained as modular diagnostic runners for targeted troubleshooting if a single role fails. They are not the primary deployment path.
- **Expected Result**: All 5 plays complete with `failed=0`; all baseline packages, services, and configs deployed.
- **Failure Condition**: Task failure on any play $\to$ Playbook halts; inspect error log and address before proceeding.

#### Step 9: Controlled Puppet CA Enrollment & Supervised Handover (`ansible/playbooks/enroll-puppet-agents.yml`)
- **Purpose**: Execute the 9-step controlled CA enrollment sequence across 3 dedicated plays:
  - Play 1 (`hosts: puppet_agents`): Verify TCP 8140 reachability from agents to Puppet Server.
  - Play 2 (`hosts: puppet_server`): Inspect pending CSRs, verify allowlisted certnames (`app-server`, `cicd-server`), reject unknown CSRs, and perform individual signing via `puppetserver ca sign`.
  - Play 3 (`hosts: puppet_agents`): Verify SSL certificate presence, execute supervised initial catalog run (`timeout 300 puppet agent -t --detailed-exitcodes`), validate exit code 0 or 2, and activate/enable the agent systemd service strictly upon catalog success (ADR 012).
- **Command**:
  ```bash
  ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/enroll-puppet-agents.yml
  ```
- **Expected Result**: Both agents enrolled, initial catalog successfully applied, `puppet` systemd service active and enabled.
- **Failure Condition**: Unrecognized CSR or catalog exit code 1 or 4 $\to$ Playbook halts; agent daemons remain disabled.

#### Step 10: Fleet Connectivity & Baseline Health Verification
- **Purpose**: Validate end-to-end functionality across the provisioned fleet.
- **Commands**:
  ```bash
  ansible -i ansible/inventory/hosts.ini all -m ping
  curl -I "http://$(terraform -chdir=terraform output -raw application_public_ip)/healthz"
  ```
- **Expected Result**: All 3 nodes respond `pong`; `/healthz` returns HTTP 200 `OK`.

#### Step 11: Export Run Logs & Diagnostic Artifacts
- **Purpose**: Persist deployment logs for auditability and compliance.
- **Procedure**: Capture Ansible execution logs into timestamped files in `/tmp/deployment-logs/`.

#### Step 12: Ephemeral Demonstration & Assessment Execution
- **Purpose**: Perform repository analysis, test analyzer container execution, and demonstrate platform capabilities.
- **Procedure**: Execute demonstration workloads within the approved session time window under ADR 011.

#### Step 13: Pre-Teardown Artifact Export Gate
- **Purpose**: Save generated analysis reports, charts, and audit metrics before ephemeral infrastructure is destroyed.
- **Procedure**: Export required files from EC2 instances to local disk or Git repository.

#### Step 14: Explicit Infrastructure Teardown Approval Gate
- **Purpose**: Prevent unintended cloud charges while ensuring that no destruction occurs without operator consent.
- **Procedure**: Confirm with operator that the demonstration session is complete and authorization is granted for teardown.
- **Failure Condition**: Operator requests session extension $\to$ Retain fleet; reschedule teardown approval gate.

#### Step 15: Ephemeral Infrastructure Teardown (`terraform destroy`)
- **Purpose**: Terminate all EC2 instances, release public IPv4 allocations, and remove security groups.
- **Command**:
  ```bash
  cd terraform && terraform destroy
  ```
  *(Execute interactively without `-auto-approve`; require operator confirmation prompt `yes`).*
- **Expected Result**: All 3 EC2 instances destroyed; attached 50 GB gp3 EBS volumes deleted; estimated active fleet running cost (approximately $0.0773/hour) is eliminated. However, actual AWS account charges may remain from persistent resources (such as the S3 state backend) or external account-level services.
- **Clarification on Retained AWS Costs**:
  - `terraform destroy` terminates all ephemeral compute, storage, and networking resources managed by Terraform.
  - **However, it does not necessarily eliminate all AWS account costs.**
  - **Persistent S3 Remote State Backend (`git-repo-analyzer-terraform-state-2026`)**: The S3 remote state bucket and its versioned history remain active in AWS region `ap-south-1`. This bucket is a permanent resource that must **never** be deleted, replaced, or modified. Its minimal storage cost (typically <$0.01/month) is absorbed by active promotional credits ($107.98 net remaining).
  - Any external account-level resources (such as AWS KMS keys, Route 53 zones, or other non-Terraform resources) remain governed by standard account billing.

---

## 8. Ephemeral vs. Persistent Lifecycle & Data Management (Retained AWS Costs)

Under **ADR 011**, all compute and host storage is ephemeral, designed for rapid demonstration and complete teardown:

| Category | Component / Data Item | Persistence Status | Storage Location & Retention Policy |
| :--- | :--- | :--- | :--- |
| **Persistent** | Codebase & Configurations | **Permanent** | Version-controlled in Git repository. |
| **Persistent** | Terraform Remote State | **Permanent** | S3 bucket `git-repo-analyzer-terraform-state-2026`. Retained permanently. Never destroyed or modified. |
| **Ephemeral** | EC2 Virtual Machines | **Destroyed** | Terminated on `terraform destroy`. |
| **Ephemeral** | EBS Root Volumes (50 GB) | **Destroyed** | Deleted on termination (`delete_on_termination = true`). |
| **Ephemeral** | Puppet CA Keys & Database | **Destroyed** | Destroyed with EC2 1. Reinitialized on next apply. |
| **Ephemeral** | Jenkins Jobs & Workspaces | **Destroyed** | Destroyed with EC2 3. Recreated on next apply. |
| **Ephemeral** | Docker Image Caches | **Destroyed** | Repulled from Docker Hub on next session. |
| **Ephemeral** | Nagios History & Metrics | **Destroyed** | Destroyed with EC2 2. |
| **Exportable**| Generated Analysis Reports | **Session-Bound** | Must be exported to local disk or Git prior to `terraform destroy`. |

---

## 9. Technical Status Classification: Detailed Verification Evidence

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
