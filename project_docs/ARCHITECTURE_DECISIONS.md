# Architecture Decisions: Git Repository Analyzer

This Architecture Decision Record (ADR) logs all approved architectural, infrastructural, networking, security, and integration decisions for the Git Repository Analyzer project.

---

## ADR 001: Three Dedicated EC2 Instances Architecture

- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** The system requires continuous configuration management, a user-facing web application, and high-intensity CI/CD pipelines executing Docker containers. Running all components on a single monolithic instance creates memory exhaustion, port conflicts, security exposure, and single points of failure.
- **Decision:** Split the infrastructure into exactly three dedicated EC2 instances:
  1. **Puppet Server:** Dedicated configuration management and Certificate Authority (CA).
  2. **Application + Monitoring Server:** React frontend, Node.js / Express backend, NGINX reverse proxy, Nagios Core.
  3. **CI/CD + Analysis Server:** Jenkins automation controller, Docker engine, analyzer container execution, NRPE monitoring daemon.
- **Consequences:** Provides process and resource isolation, dedicated CA security boundaries, and modular scalability, at the cost of managing inter-node networking and multi-instance lifecycle.

---

## ADR 002: Preservation of Existing S3 Remote State Backend with Native S3 State Locking

- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** An S3 remote state backend is configured in `terraform/main.tf` targeting bucket `git-repo-analyzer-terraform-state-2026` in region `ap-south-1`. Terraform 1.10+ introduced native S3 state locking via S3 lockfiles (`use_lockfile = true`), eliminating the legacy DynamoDB table requirement.
- **Decision:** Strictly preserve the existing S3 remote state backend block without modification, destruction, or recreation. The three-node infrastructure will be deployed into this exact backend.
- **Consequences:** Avoids state migration risks, leverages existing encrypted and versioned S3 infrastructure, and simplifies lock management without DynamoDB overhead.

---

## ADR 003: Strict Directional Security Group Rules & Zero Public Exposure for Internal Services

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved & Implemented in Terraform Code (Commit `3dc7870`)
- **Context:** Exposing internal orchestration, configuration management, or CI/CD services (Puppet on 8140, Jenkins on 8080, NRPE on 5666) to the public internet (`0.0.0.0/0`) or broad operator CIDRs creates critical attack vectors for unauthorized code execution and configuration tampering.
- **Decision:** Enforce strict directional security group ingress verified against `terraform/modules/ec2/main.tf`:
  - **EC2 2: Application + Monitoring Server (`app_monitoring_sg`):**
    - `TCP 80` (HTTP): Ingress from `0.0.0.0/0` (public web access for React frontend).
    - `TCP 443` (HTTPS): Ingress from `0.0.0.0/0` (public secure web access).
    - `TCP 22` (SSH): Ingress strictly restricted to operator public IP `/32` (`var.allowed_ssh_cidr`).
    - Outbound Egress: `0.0.0.0/0` (all traffic).
  - **EC2 1: Dedicated Puppet Server (`puppet_server_sg`):**
    - `TCP 8140` (Puppet Server): Ingress strictly restricted to `app_monitoring_sg` and `cicd_analysis_sg` security group references. Zero public or operator CIDR access.
    - `TCP 5666` (NRPE): Ingress strictly restricted to `app_monitoring_sg` security group reference (for Nagios monitoring queries). Zero public access.
    - `TCP 22` (SSH): Ingress strictly restricted to operator public IP `/32` (`var.allowed_ssh_cidr`).
    - Outbound Egress: `0.0.0.0/0` (apt and Puppet Forge updates).
  - **EC2 3: CI/CD & Analysis Server (`cicd_analysis_sg`):**
    - `TCP 8080` (Jenkins API): Ingress strictly restricted to `app_monitoring_sg` security group reference (allowing backend API calls only). Zero public or operator CIDR access.
    - `TCP 5666` (NRPE): Ingress strictly restricted to `app_monitoring_sg` security group reference (for Nagios monitoring queries). Zero public access.
    - `TCP 22` (SSH): Ingress strictly restricted to operator public IP `/32` (`var.allowed_ssh_cidr`).
    - Outbound Egress: `0.0.0.0/0` (apt, Docker Hub, GitHub, Groq API).
- **Public Ingress Rule:** Public HTTP/HTTPS ingress is permitted **exclusively on EC2 2**. Neither EC2 1 nor EC2 3 accepts public HTTP/HTTPS traffic. Internal management traffic is exclusively routed through AWS security group references, eliminating public attack surfaces.
- **Consequences:** Internal services are completely shielded from public discovery and scanning. Outbound public IPv4 on all nodes enables fast package retrieval without NAT Gateway costs while maintaining strict ingress boundaries.

---

## ADR 004: Nagios Administrative Access via Restricted SSH Tunneling

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved Architecture (Design Finalized; Planned for Phase 5/8)
- **Context:** Nagios Core web administration provides system process details, network topology, and administrative commands. Exposing the Nagios web interface over the public HTTP/HTTPS virtual host exposes administrative attack surfaces.
- **Decision:** Public HTTP/HTTPS on the Application Server shall serve the user application only. Nagios administration is strictly barred from public routing.
  - **Web Server & Port:** Nagios Apache web interface binds strictly to loopback: `127.0.0.1:8080`.
  - **Authentication:** Enforces HTTP Basic Authentication (`.htpasswd` for `nagiosadmin`).
  - **Reverse Proxy Separation:** NGINX serves the React frontend and reverse-proxies `/api/` to Express. NGINX will **not** expose or proxy `/nagios`.
  - **Encrypted SSH Tunnel:** Operators access the Nagios web console via an encrypted SSH tunnel:
    `ssh -i ~/.ssh/git-repo-analyzer.pem -L 8080:127.0.0.1:8080 ubuntu@<app-server-public-ip>`
  - **Browser Endpoint:** `http://localhost:8080/nagios`
  - **Implementation Status Distinction:**| Component                              | Current Status                |
    | -------------------------------------- | ----------------------------- |
    | Terraform SG rules for NRPE (TCP 5666) | Implemented and validated     |
    | Nagios Core                            | Planned; not installed        |
    | NRPE daemon and plugins                | Planned; not installed        |
    | Apache loopback configuration          | Planned; not installed        |
    | HTTP Basic Authentication              | Planned; not configured       |
    | SSH tunnel access                      | Design documented; not tested |
- **Consequences:** Eliminates brute-force attacks and vulnerability exploitation against Nagios web scripts, ensuring operational dashboards remain private.

---

## ADR 005: Compute & Storage Sizing Under Post-July 2025 Free Plan Model

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved & Implemented in Terraform Code (Commit `3dc7870`; Provisioning On-Demand)
- **Context:** AWS updated its Free Tier model on July 15, 2025. For accounts created under this model, initial credits apply over a validity window. As verified in the November 18, 2026 billing snapshot, the account has two distinct timelines: the **AWS Free Plan duration expires on March 12, 2027** (115 days remaining from snapshot), while **promotional credits expire on September 12, 2027** (12-month validity window). Total credits issued: **$120.00** across two grants ($100.00 AWS Free Tier Promotion + $20.00 EC2 Launch Promotion); invoiced credits consumed: **$5.32** (drawn from the $100.00 grant); remaining active promotional credit balance: **$114.68** ($94.68 Free Tier active + $20.00 EC2 Launch active); estimated net remaining credit balance: **$107.98** (reflecting $114.68 active balance minus $6.70 in estimated unbilled month-to-date usage from Cost Explorer; all unbilled figures are estimates). Eligible EC2 families include `t3.micro`, `t3.small`, etc. Compute draws against available credits or incurs on-demand rates ($0.0112/hr for `t3.micro`, $0.0224/hr for `t3.small` in `ap-south-1`).
- **Provisional Sizing & Storage Allocation (Pre-Deployment Estimates):**
  - **Puppet Server (Instance 1):** `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS). Estimated JVM heap (`-Xms1g -Xmx1g` in `/etc/default/puppetserver`) houses 1 JRuby instance (`max-active-jrubies: 1`). Estimated steady-state RAM consumption is ~1.47 GB, leaving ~530 MB physical headroom.
  - **Application + Monitoring Server (Instance 2):** `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS). Estimated steady-state memory footprint (NGINX + Node.js Express + Nagios Core C-daemon + Apache loopback) is ~440 MB, leaving ~560 MB physical headroom. During a periodic Puppet Agent run (+250 MB), estimated peak usage is ~690 MB, leaving ~310 MB physical headroom. A 1.0 GB swapfile acts strictly as an auxiliary shock-absorber against kernel OOM panics.
  - **CI/CD + Analysis Server (Instance 3):** `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS). Sequential pipeline execution (Jenkins controller JVM tuned to `-Xms384m -Xmx512m` + Docker daemon + analyzer container + agent) peaks at an estimated ~1.50 GB RAM, leaving ~500 MB physical headroom. A 2.0 GB swapfile provides an auxiliary cushion. 20 GB gp3 storage accommodates Docker image layers (`git-repo-analyzer`), Jenkins home, cloned target workspaces, and build artifacts.
  - **Fleet Storage Total:** Exactly 50 GB gp3 across the fleet (15 GB + 15 GB + 20 GB).
- **Operational Risks by Instance (Pre-Deployment Estimates):**
  - *EC2 1 (Puppet Server)*: JRuby heap exhaustion and Metaspace bloat. Default Puppet Server heap is 2 GB, requiring manual tuning to `-Xms1g -Xmx1g` with `max-active-jrubies: 1` to prevent immediate OOM panic. Concurrent catalog compilation requests could deplete the ~530 MB headroom.
  - *EC2 2 (App + Monitoring)*: Memory contention on 1 GB physical RAM. Baseline consumes ~440 MB; Puppet Agent catalog compilation adds ~250 MB (~690 MB peak, ~70% RAM). Concurrent HTTP traffic surges or Nagios check storms could cause thrashing or trigger the kernel OOM killer. Ansible configures a 1.0 GB swapfile as an emergency safety net.
  - *EC2 3 (CI/CD + Analysis)*: Concurrent workload spikes. Simultaneous execution of Jenkins JVM (~520 MB), Docker analyzer container (~350 MB typical, capped at 1 GB), and Puppet Agent (~250 MB) consumes ~1.50–1.80 GB RAM. Mitigated by sequential build queues (`# of executors = 1`) and a 2.0 GB swapfile cushion.
  - *Fleet-Wide T3 CPU Credit Risk*: Initial bootstrap bursts (package installation, Docker pull, JVM startup) deplete launch credits. In Unlimited mode, depleted credits incur $0.05/vCPU-hour surplus charges.
- **Swap Thresholds & Workload Limits:**
  - *Normal Steady-State*: Swap in-use must remain `< 50 MB` (near 0 MB).
  - *Emergency Peak Ceiling*: Swap in-use must remain `< 200 MB` during catalog application spikes. Swap is not a replacement for physical RAM; active paging causes severe latency thrashing.
- **CPU Credit and Surplus Charge Monitoring:**
  - T3 instances operate in Unlimited mode by default. We make **no guarantee** that baseline credits can sustain a four-hour demonstration without surplus charges ($0.05 per vCPU-hour).
  - *Active Live Validation Metrics*: CloudWatch `CPUCreditBalance`, `CPUSurplusCreditCharged`, `CPUUtilization`; host load averages (`/proc/loadavg`); available memory (`/proc/meminfo` `MemAvailable`, `SwapFree`); real-time container stats (`docker stats --no-stream`).
  - *Sizing Policy*: Retain provisional sizing (`t3.small` / `t3.micro` / `t3.small`) without resizing until live workload benchmarking during Phase 4 and Phase 7 produces verified empirical data.
- **Outbound Internet Access Strategy:** All three instances are explicitly configured with `associate_public_ip_address = true` within the Default VPC public subnets, routing through the attached Internet Gateway. Internal management ports (8140, 8080, 5666) are strictly closed to the public internet via security group references, and SSH (port 22) is restricted to the operator CIDR.
- **Operating Cost & Ephemeral Lifecycle:** Limits estimated project expenditure during on-demand demonstration sessions to ~$0.0773 per running hour across the entire three-node fleet (Compute $0.0560 + IPv4 $0.0150 + 50 GB EBS $0.00625). Actual costs are provisional estimates subject to account-level spend, credit eligibility rules, and additional usage charges. Live provisioning is governed under ADR 010 and ADR 011.

---

## ADR 006: Separation of Responsibilities Between Ansible and Puppet

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved
- **Context:** Using both Ansible and Puppet without clear boundaries can lead to configuration races, conflicting file ownership, and configuration flapping.
- **Decision:** Partition responsibilities strictly by operational lifecycle with an explicit resource ownership matrix:

| Resource / Subsystem                   | Bootstrap Owner (Ansible)    | Desired-State Owner (Puppet)  | Handover & Operational Policy                                                                                    |
| :------------------------------------- | :--------------------------- | :---------------------------- | :--------------------------------------------------------------------------------------------------------------- |
| **Base OS Packages & Tools**     | Installs initial packages    | Maintains package baseline    | Ansible bootstraps once; Puppet manages ongoing packages.                                                        |
| **Swapfile Configuration**       | Creates & activates swapfile | -                             | Ansible safely configures `/swapfile` (1 GB EC2 2, 2 GB EC2 3, 0 MB EC2 1) across 9 safety/lifecycle scenarios (preserves valid swap, rejects directories/symlinks, verifies exact size, checks `blkid -p` swap signature, avoids duplicate swapon, updates `/etc/fstab` idempotently, leaves zero-swap untouched). |
| **Private DNS (`/etc/hosts`)** | Injects initial private IPs  | Enforces `/etc/hosts` drift | Ansible derives private IPs dynamically from Terraform inventory (`hostvars[host]['private_ip']`); Puppet enforces consistency. |
| **Docker Engine & Plugins**      | Installs Docker CE on EC2 3  | -                             | Ansible configures Docker; adds `ubuntu` to `docker` group.                                                  |
| **Puppet Server & CA**           | Installs & tunes JVM heap    | -                             | Ansible installs packages, tunes JVM heap (-Xms1g -Xmx1g), limits JRuby (max-active-jrubies: 1), enforces puppet.conf with autosign=false, and executes 3-state CA initialization before service startup. Enforces official PuppetLabs vendor package (`apt.puppet.com`) via APT pinning (`Pin-Priority: 900`) over Ubuntu Universe to preserve `/opt/puppetlabs/` filesystem standards and ensure full interoperability with fleet `puppet-agent`. |
| **Puppet Agent & Enrollment**    | Installs agent & CSR submit  | -                             | Ansible installs official vendor package, configures stable identity (`app-server` / `cicd-server`), submits CSR, and preserves SSL state. Certificate approval and signing belong exclusively to Checkpoint 4.5. |
| **NGINX Virtual Host & Config**  | Installs baseline package    | **Exclusively Owns**    | Ansible installs package; Puppet manages virtual hosts and proxies.                                              |
| **Node.js 20 LTS Runtime**       | -                            | **Exclusively Owns**    | Puppet deploys and manages Node.js runtime on EC2 2.                                                             |
| **Backend Systemd Service**      | -                            | **Exclusively Owns**    | Puppet deploys `git-repo-analyzer-backend.service` (runs as unprivileged user `gitrepo`, group `gitrepo`). |
| **Backend Environment File**     | -                            | **Exclusively Owns**    | Puppet deploys `/etc/git-repo-analyzer/backend.env` (`root:gitrepo`, mode `0640`).                         |
| **Nagios Core & Plugins**        | -                            | **Exclusively Owns**    | Puppet compiles, configures, and manages Nagios on EC2 2.                                                        |
| **NRPE Daemon & Checks**         | -                            | **Exclusively Owns**    | Puppet configures `nrpe.cfg` and check scripts on EC2 1 & EC2 3.                                               |

- **Handover Mechanism:** Once a node is enrolled in Puppet, Ansible will never execute plays that manage or overwrite NGINX virtual hosts, application systemd units, environment files, or Nagios/NRPE configurations.
- **Puppet Server 8 Packaging Strategy on Ubuntu 24.04 LTS (Noble):**
  - *Distro Option A (Ubuntu Noble Universe `8.4.0-1`)*: Rejected. Debian/Ubuntu packaging fractures the standard Puppet filesystem hierarchy by placing binaries in `/usr/bin/puppetserver` and configuration in `/etc/puppet/`. Furthermore, it depends on distro-packaged `puppet-agent` (`/usr/bin/puppet`), which breaks compatibility with official PuppetLabs agents (`/opt/puppetlabs/bin/puppet`) deployed across the fleet, disrupts CA CLI paths, and locks the server into an unmaintained point release (`8.4.0`).
  - *Vendor Option B (PuppetLabs Upstream Jammy Fallback `8.7.0-1jammy`)*: Approved. The official package `puppetserver_8.7.0-1jammy_all.deb` is architecture-independent Java bytecode (`Architecture: all`) running on OpenJDK 17 (`openjdk-17-jre-headless`, natively available in Noble). It installs into the vendor hierarchy (`/opt/puppetlabs/server/apps/puppetserver/`, `/opt/puppetlabs/bin/puppetserver`, `/etc/puppetlabs/puppetserver/conf.d/`), fully interoperates with official `puppet-agent` (`8.10.0-1noble`), and receives active 8.x maintenance.
  - *Repository Isolation & APT Pinning*: To ensure APT installs the vendor package rather than distro universe, Ansible deploys `/etc/apt/preferences.d/puppetlabs.pref` pinning `origin apt.puppet.com` with priority 900 (superseding distro priority 500). Ansible evaluates `apt-cache madison puppetserver | grep -E 'apt\.puppet\.com.*noble'` before enabling the Jammy fallback repository, avoiding false positives from the Universe archive.
- **Puppet Agent 8 Packaging and CSR Registration Strategy (Ubuntu 24.04 LTS):**
  - *Native Vendor Packaging*: Unlike Puppet Server, `puppet-agent` (version 8.10.x) is natively published in PuppetLabs' Noble repository (`apt.puppet.com noble puppet8`). No Jammy fallback is needed or permitted on agent nodes.
  - *Distro Package Rejection*: APT preferences in `/etc/apt/preferences.d/puppetlabs.pref` pin `origin apt.puppet.com` with priority 900, ensuring the official vendor package (`/opt/puppetlabs/bin/puppet`) is selected and Ubuntu Universe's distro package (`8.4.0-1` in `/usr/bin/puppet`) is rejected.
  - *Stable Agent Identities*: Agent nodes configure `server = puppet-server` and stable certnames (`app-server` on EC2 2, `cicd-server` on EC2 3) under `[main]` in `/etc/puppetlabs/puppet/puppet.conf` with `runinterval = 30m`. Configuration updates use non-destructive INI modifications (`community.general.ini_file`), preserving custom sections and comments.
  - *Preflight Network Assertions & Reachability Gating*: DNS resolution verifies that `puppet-server` resolves to the private IP defined in inventory, and TCP port 8140 reachability is probed with actionable diagnostics. Strict mode defaults to `puppet_agent_require_server_reachable: true`, ensuring live runs fail fast when the server is unreachable. Offline testing explicitly sets `puppet_agent_require_server_reachable: false`.
  - *CSR Submission Boundary & Cryptographic Safety*: The agent role distinguishes remote submission from local offline generation. When the server is reachable, it executes `puppet ssl submit_request` and fails fast on any non-zero exit code (`failed_when: puppet_csr_submit_result.rc != 0`). When offline mode is explicitly requested and the server is unreachable, it executes `puppet ssl generate_request` to produce local keys and CSRs without network attempts, explicitly reporting that submission is deferred rather than claiming "pending CA approval". Existing CSRs and valid certificates are verified and preserved intact without resubmission or key regeneration. The role strictly prohibits:
    1. Enabling autosigning on server or agent.
    2. Executing `puppetserver ca sign` (belongs exclusively to Checkpoint 4.5).
    3. Copying CA private keys to agent nodes.
    4. Sharing or copying private keys between agents.
    5. Automatic key regeneration or destructive SSL cleanup (`rm -rf /etc/puppetlabs/puppet/ssl`).
    6. Overwriting valid existing certificates or ignoring certname mismatches.
    7. Suppressing real submission failures in live deployment.
  - *Service Daemon Gating & Controlled Catalog Invariant*: The agent systemd service defaults to `state: stopped` and `enabled: true` during Checkpoint 4.4. Leaving the daemon stopped prevents it from polling the CA in the background, eliminating race conditions where the daemon could automatically download a newly-signed certificate and apply catalogs without Ansible supervision. Handlers guard `restart puppet agent` with `when: puppet_agent_service_state | default('stopped') == 'started'`, ensuring configuration updates never accidentally start a stopped service. Supervised catalog execution (`puppet agent -t --detailed-exitcodes`) and service startup are deferred strictly to Checkpoint 4.5.
- **Consequences:** Completely eliminates configuration conflicts and flapping between automation tools, while preserving strict vendor filesystem standards across all nodes.

---

## ADR 007: Jenkins Root-Equivalent Docker Group Membership & Analyzer Execution Isolation

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved
- **Context:** The analyzer runs inside a Docker container. For Jenkins to execute `docker run` from pipeline steps without requiring interactive sudo passwords, the `jenkins` system user must be added to the `docker` Unix group. Untrusted repositories submitted for analysis must be strictly sandboxed.
- **Decision:** Add the `jenkins` user to the `docker` group on Instance 3 (deferred to Phase 7 upon Jenkins installation), explicitly recognizing this as root-equivalent access on the CI/CD host, while enforcing strict container execution sandboxing:
- **Container Isolation & Execution Sandboxing Requirements:**
  1. **Git Hooks Prohibited:** Git execution strictly specifies `-c core.hooksPath=/dev/null` on clone, fetch, and checkout to ensure untrusted `.git/hooks` never execute.
  2. **Zero Script/Binary Execution:** The analyzer container strictly inspects Git metadata (`git log`, `git shortlog`, `git rev-parse`) and runs static line counting (`cloc`). No repository scripts, makefiles, or binaries are ever executed.
  3. **No Recursive Submodules:** Git clone/fetch enforces `--no-recurse-submodules`.
  4. **Execution Timeouts:** Git clone is bounded to 5 minutes; analysis container run is bounded to 10 minutes.
  5. **Resource Limits:** Docker run enforces `--memory=1g`, `--cpus=1.5`, `--pids-limit=100`, and repository disk allocation is capped at 2 GB.
  6. **Non-Root Execution:** Container execution enforces `--user $(id -u):$(id -g)` preventing root ownership or privilege escalation.
  7. **Temporary Workspace Hygiene:** Container runtime filesystem is discarded on exit via `docker run --rm` (**IMPLEMENTED**). Comprehensive host workspace directory cleanup across all execution paths (success, failure, abort, timeout) is specified and to be implemented in Phase 7 via `post { cleanup { cleanWs() } }` in `Jenkinsfile` (**SPECIFIED**).
  8. **Credential & Daemon Isolation:** Jenkins credentials are never passed into the container; the host Docker socket (`/var/run/docker.sock`) is **never mounted**.
- **Consequences:** Enables smooth containerized analysis while documenting and containing the root-equivalence security trade-off.

---

## ADR 008: Decoupled CI/CD Workflow

- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** Building the analyzer Docker image on-demand for every repository analysis request introduces extreme latency (npm package installation, graphics library compilation).
- **Decision:** Maintain a two-tier decoupled automation model:
  1. **Analyzer Image CI (GitHub Actions):** On push to the analyzer repository, GitHub Actions builds, tests, and publishes the validated image to Docker Hub (`adityaashok2274/git-repo-analyzer:latest`).
  2. **Operational Analysis CD (Jenkins):** Jenkins consumes the pre-built, tested Docker Hub image to analyze target repositories. Jenkins never builds the analyzer image itself.
- **Consequences:** Analysis pipeline starts immediately with `docker pull` without build overhead.

---

## ADR 009: Canonical Resource-Oriented Backend API and Jenkins Asynchronous Ingestion

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved (Supersedes previous `/api/analyze` contract)
- **Context:** Repository analysis involving Git log extraction, deterministic metrics, chart generation, and LLM inference can take 15–60 seconds. A synchronous HTTP request from frontend to backend would time out. The API design must be resource-oriented, robust, and cleanly separated from internal Jenkins identifiers.
- **Decision:** Establish a canonical resource-oriented API contract (`/api/analyses`) backed by an asynchronous polling and artifact ingestion lifecycle:
  - **Public Endpoints:**
    - `GET /api/health`: Returns `{ "status": "UP", "timestamp": "..." }` (HTTP 200).
    - `POST /api/analyses`: Accepts `{ "repositoryUrl": "https://github.com/owner/repo" }`. Validates URL via strict parsing and SSRF guards. Generates an application-level UUID v4 `analysisId`. Dispatches parameterized build to Jenkins. Returns HTTP 202 Accepted with `{ "analysisId": "550e8400-e29b-41d4-a716-446655440000", "status": "QUEUED", "createdAt": "..." }`.
    - `GET /api/analyses/:id`: Returns HTTP 200 with strictly application-level metadata:
      ```json
      {
        "analysisId": "550e8400-e29b-41d4-a716-446655440000",
        "status": "BUILDING",
        "progress": "Analyzing commit activity...",
        "createdAt": "2026-11-22T18:00:00.000Z",
        "updatedAt": "2026-11-22T18:00:15.000Z",
        "error": null
      }
      ```
    - `GET /api/analyses/:id/results`: Returns HTTP 200 with `{ "analysisId": "550e8400-e29b-41d4-a716-446655440000", "status": "COMPLETED", "metrics": { ... }, "summaryMarkdown": "...", "charts": { "commitsPerAuthor": "...", "dailyActivity": "..." } }`. Returns HTTP 404 if analysis is not complete.
  - **Deprecated Endpoints:** Legacy endpoints (`POST /api/analyze`, `GET /api/status/:buildId`, `GET /api/reports/:buildId`) are officially retired and superseded.
  - **Identifier Abstraction Policy:** The public API exposes strictly application-generated UUIDs (`analysisId`). Internal Jenkins queue item IDs and build numbers are resolved and mapped internally by the Express backend (`analysisId` $\rightarrow$ `queueId` $\rightarrow$ `buildNumber`) and are never exposed to clients.
  - **Status Mapping Lifecycle:**
    - Jenkins Queue Item $\rightarrow$ Backend `QUEUED`.
    - Jenkins Building (`building: true`) $\rightarrow$ Backend `BUILDING`.
    - Jenkins `result: "SUCCESS"` $\rightarrow$ Backend `COMPLETED` (triggers artifact ingestion).
    - Jenkins `result: "FAILURE"` $\rightarrow$ Backend `FAILED`.
    - Jenkins `result: "ABORTED"` $\rightarrow$ Backend `CANCELLED`.
  - **Artifact Ingestion & Caching:** Upon `COMPLETED` status, backend fetches `metrics.json`, `summary.md`, and PNG charts from Jenkins build artifacts over the private network and caches them in local disk cache.
  - **Polling & Timeout Policy:** React frontend polls `/api/analyses/:id` every 2–3 seconds with exponential backoff up to 10 seconds. Overall timeout ceiling is 10 minutes.
  - **Error Response Standard:** Consistent JSON error payload: `{ "error": { "code": "VALIDATION_ERROR", "message": "...", "details": ... } }`.
- **Consequences:** Eliminates gateway timeouts, shields internal Jenkins job details from clients, and provides structured progress feedback.

---

## ADR 010: AWS Cost Governance, Two-Tier Approval Boundaries, and Credit Lifecycle

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved (Permanent Governance Standard)
- **Context:** Cloud infrastructure provisioning carries financial liability through recurring compute, storage, public IP, and network egress charges. As of the verified November 18, 2026 snapshot, the account operates under the AWS Free Plan window (ending March 12, 2027) with a remaining active promotional credit balance of **$114.68** ($94.68 AWS Free Tier active + $20.00 EC2 Launch active from $120.00 total issued, with $5.32 invoiced used; estimated net balance $107.98 after subtracting $6.70 estimated unbilled month-to-date usage) valid through September 12, 2027. All projections beyond this snapshot are unverified estimates.
- **Decision:** Establish strict cost governance protocols across all autonomous agent actions and human operator workflows:
  1. **Strictly Separate Implementation vs Provisioning Approvals**:
     - **Approval Boundary A (Phase Implementation Approval):** Authorization to create or modify local code, Ansible playbooks, Puppet manifests, tests, and documentation.
     - **Approval Boundary B (AWS Provisioning Approval):** Authorization to execute `terraform apply` and create billable AWS cloud resources.
     - **Rule:** Approval for Boundary A **never implies** approval for Boundary B. Authoring Phase 4 code does not authorize live AWS infrastructure creation.
  2. No AWS infrastructure resource may be provisioned until its estimated cost, Free Tier eligibility, and potential additional charges have been reviewed and explicitly approved by the project owner under Boundary B.
  3. Live Ansible execution against EC2 requires the infrastructure to exist and explicit operator authorization to perform that execution.
  4. Never assume Free Tier eligibility based solely on an instance family, size, or service category. Verify eligibility against the applicable account offer and AWS region.
  5. Provide cost comparisons and technical justification before requesting approval.
  6. Never execute Terraform apply, create AWS resources, or incur infrastructure charges without explicit Boundary B approval.
  7. Cost optimization must not silently compromise the approved architecture, security requirements, or minimum workload requirements.
  8. Treat all infrastructure sizes and cost estimates as provisional until explicitly approved.
- **Consequences:** Eliminates accidental cloud billing, enforces transparency before infrastructure mutation, and maintains strict alignment with project owner budget constraints.

---

## ADR 011: On-Demand Infrastructure Lifecycle Strategy (Ephemeral Provisioning & Teardown)

- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved
- **Context:** The Git Repository Analyzer is an educational, demonstration, and assessment system. It is not a permanent public web service requiring 24/7 availability. Running three EC2 instances continuously would exhaust account promotional credits unnecessarily.
- **Decision:** Implement an on-demand, ephemeral infrastructure lifecycle structured across 10 sequential operational steps:
  1. **Explicit Owner Approval (Boundary B):** Review estimated session costs and verify AWS account credits.
  2. **Terraform Apply:** Provision the 3 EC2 instances, security groups, and 50 GB gp3 storage.
  3. **Ansible Bootstrap:** Verify authentic host keys, configure `/etc/hosts`, swapfiles, and install base packages, Docker, and Puppet binaries.
  4. **Puppet CA & Enrollment:** Cryptographically verify CA, submit agent CSRs, and perform controlled per-certname signing.
  5. **Application Deployment:** Deploy Node.js runtime, backend systemd service (user `gitrepo`), React static build, and NGINX reverse proxy.
  6. **Jenkins & Analyzer Integration:** Start Jenkins controller, configure pipeline, and test Docker analyzer container execution with sandboxing.
  7. **Monitoring Validation:** Start Nagios Core and NRPE daemons; verify telemetry over SSH tunnel.
  8. **Demonstration & Testing:** Perform live analysis of public repositories and review generated reports and metrics.
  9. **Artifact Export:** Export required reports, charts, and audit metrics to local disk or Git repository before teardown.
  10. **Terraform Destroy:** Terminate all three EC2 instances, release public IPv4 addresses, and delete EBS root volumes (`delete_on_termination = true`).
- **Data Boundaries (Persistent vs. Ephemeral):**
  - **Persistent Infrastructure (Survives Teardown):**
    - Git repository codebase, configuration files, playbooks, manifests, and documentation.
    - S3 remote state bucket (`git-repo-analyzer-terraform-state-2026`). The bucket must never be destroyed during session teardowns.
  - **Ephemeral Infrastructure (Destroyed on Teardown):**
    - All 3 EC2 instances and attached EBS root volumes (50 GB total).
    - Puppet CA private keys, certificate database, and agent certificates.
    - Jenkins build jobs, workspaces, build history, and stored credentials.
    - Docker daemon image caches and container runtimes.
    - Nagios monitoring state history and runtime logs.
    - Express backend memory state and local report caches.
- **Private Key Storage Standard:** The canonical location for private keys is `~/.ssh/git-repo-analyzer.pem` with mode `0400`. Keeping private keys in the repository workspace (even if git-ignored) is an operational security risk; `.gitignore` is not an equivalent security substitute for external storage.
- **Production-Ready vs. Demonstration-Ready Distinction:** The project target is explicitly **demonstration-ready**, optimized for low-cost ephemeral execution, rather than an enterprise high-availability 24/7 production service.
- **Consequences:** Limits demonstration session costs to ~$0.31 (4 hours) or ~$1.24/month for weekly demos, while preserving account credits. Requires conscious export of desired artifacts before teardown.

---

## ADR 012: Two-Phase Puppet Agent Service Lifecycle & Gated Startup Invariant

- **Date:** 2026-11-23
- **Status:** Approved
- **Context:** In Checkpoint 4.4, Puppet Agent packages are installed, configurations deployed, and CSRs generated/submitted. If the `puppet` systemd service unit is enabled or started during this initial phase, the background daemon could start automatically upon a host reboot or poll the Puppet Server continuously in the background. The instant an administrator signs the agent's certificate on EC2 1 during Checkpoint 4.5, a running background daemon would automatically fetch the signed certificate and compile/apply the node catalog without Ansible supervision or operator observability.
- **Decision:** Enforce a strict two-phase service lifecycle governing the Puppet Agent:
  1. **Phase 1 — Checkpoint 4.4 Bootstrap Invariant (Disabled & Stopped):**
     - The agent systemd service defaults strictly to `puppet_agent_service_enabled: false` and `puppet_agent_service_state: "stopped"`.
     - Configuration handlers in `handlers/main.yml` are guarded with `when: puppet_agent_service_state | default('stopped') == 'started'` and `puppet_agent_service_enabled | default(false) | bool`.
     - The service remains dormant and will not start across system reboots or configuration notifications.
  2. **Phase 2 — Checkpoint 4.5 Handover Sequence (Supervised Enforcement & Startup):**
     - Certificate signing on EC2 1 must be verified.
     - Initial catalog application must be executed under Ansible supervision: `puppet agent -t --detailed-exitcodes`, asserting documented clean exit codes (`0` or `2`).
     - Only after successful catalog verification are `puppet_agent_service_enabled: true` and `puppet_agent_service_state: "started"` explicitly enforced.
     - The agent service must **never** be enabled or started merely because a CSR was signed.
- **Consequences:** Eliminates background polling races and guarantees that the initial catalog application is completely observable, deterministic, and verified by Ansible before continuous daemon polling is activated.
