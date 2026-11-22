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
- **Decision:** Enforce strict directional security group ingress using AWS security group cross-references:
  - **Jenkins (Port 8080):** Ingress restricted strictly to `app_monitoring_sg` (allowing Express backend API calls only). No public or operator-CIDR ingress.
  - **Puppet Master (Port 8140):** Ingress restricted strictly to `app_monitoring_sg` and `cicd_analysis_sg`.
  - **NRPE Daemon (Port 5666):** Ingress restricted strictly to `app_monitoring_sg` on both EC2 1 (Puppet Server) and EC2 3 (CI/CD Server), allowing Nagios monitoring queries only.
  - **SSH (Port 22):** Restricted strictly to the operator CIDR (`var.allowed_ssh_cidr`) across all three instances.
  - **Public Ingress (Ports 80/443):** Restricted exclusively to `app_monitoring_sg` for user application delivery.
  - **Outbound Egress:** Enabled to `0.0.0.0/0` across all instances for package updates and API requests. Public IPv4 allocation does not bypass these ingress boundaries.
- **Consequences:** Internal services are completely shielded from public discovery and scanning.

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
  - **Implementation Status Distinction:**
    | Component | Current Status |
    |---|---|
    | Terraform SG rules for NRPE (TCP 5666) | Implemented and validated |
    | Nagios Core | Planned; not installed |
    | NRPE daemon and plugins | Planned; not installed |
    | Apache loopback configuration | Planned; not installed |
    | HTTP Basic Authentication | Planned; not configured |
    | SSH tunnel access | Design documented; not tested |
- **Consequences:** Eliminates brute-force attacks and vulnerability exploitation against Nagios web scripts, ensuring operational dashboards remain private.

---

## ADR 005: Compute & Storage Sizing Under Post-July 2025 Free Plan Model
- **Date:** 2026-11-18 (Updated 2026-11-22)
- **Status:** Approved & Implemented in Terraform Code (Commit `3dc7870`; Provisioning On-Demand)
- **Context:** AWS updated its Free Tier model on July 15, 2025. For accounts created under this model, initial credits ($100 issued, up to $200 with activity credits) apply over a 6-month validity window (ending March 12, 2027 for this account, with 115 days remaining and $107.98 in verified available credits as of the November 18, 2026 snapshot). Eligible EC2 families include `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, etc. Compute draws against available credits or incurs on-demand rates ($0.0112/hr for `t3.micro`, $0.0224/hr for `t3.small` in `ap-south-1`).
- **Implemented Sizing & Storage Configuration:**
  - **Puppet Server (Instance 1):** `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS). Default JVM heap (`-Xms2g -Xmx2g`) tuned down to `-Xms1g -Xmx1g` in `/etc/default/puppetserver`. For a 2-agent fleet, catalog compilation completes in < 5 seconds.
  - **Application + Monitoring Server (Instance 2):** `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS). Steady-state memory footprint (NGINX + Node.js Express + Nagios Core C-daemon + periodic Puppet Agent) is ~420 MB, leaving ~580 MB free RAM.
  - **CI/CD + Analysis Server (Instance 3):** `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS). Sequential pipeline execution (Jenkins controller JVM tuned to `-Xms384m -Xmx512m` + Docker daemon + analyzer container) peaks at ~1,232 MB RAM, leaving ~816 MB headroom on 2 GB RAM. A 1–2 GB swapfile provides an auxiliary safety cushion. 20 GB gp3 storage accommodates Docker image layers (`git-repo-analyzer`), Jenkins home, cloned target workspaces, and build artifacts.
  - **Fleet Storage Total:** Exactly 50 GB gp3 across the fleet (15 GB + 15 GB + 20 GB).
- **Outbound Internet Access Strategy:** All three instances are explicitly configured with `associate_public_ip_address = true` within the Default VPC public subnets, routing through the attached Internet Gateway. Internal management ports (8140, 8080, 5666) are strictly closed to the public internet via security group references, and SSH (port 22) is restricted to the operator CIDR. This allows direct, high-speed outbound downloads without the continuous overhead of an AWS NAT Gateway ($0.056/hr = ~$40.88/mo).
- **Operating Cost & Ephemeral Lifecycle:** Limits estimated project expenditure during on-demand demonstration sessions to ~$0.0773 per running hour across the entire three-node fleet (Compute $0.0560 + IPv4 $0.0150 + 50 GB EBS $0.00625). Actual costs are estimates subject to account-level spend, credit eligibility rules, and additional usage charges. Live provisioning is governed under ADR 010 and ADR 011.

---

## ADR 006: Separation of Responsibilities Between Ansible and Puppet
- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** Using both Ansible and Puppet without clear boundaries can lead to configuration races, conflicting file ownership, and configuration flapping.
- **Decision:** Partition responsibilities strictly by operational lifecycle:
  - **Ansible (Day 0/1 Bootstrap):** Owns initial base OS packages (`common`), Docker CE engine installation on Instance 3, Puppet Server installation on Instance 1, Puppet Agent installation on Instances 2 and 3, and initial SSL certificate enrollment.
  - **Puppet (Day 2+ Desired State):** Owns ongoing continuous configuration management. Enforces NGINX virtual host configurations, Node.js application services, Nagios Core configurations, NRPE check definitions, and configuration drift remediation.
  - **Rule:** Ansible will never manage application service configurations or Nagios configurations once the node is enrolled in Puppet.
- **Consequences:** Completely eliminates configuration conflicts between automation tools.

---

## 7. ADR 007: Jenkins Root-Equivalent Docker Group Membership Trade-Off
- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** The analyzer runs inside a Docker container. For Jenkins to execute `docker run` from pipeline steps without requiring interactive sudo passwords, the `jenkins` system user must be added to the `docker` Unix group.
- **Decision:** Add the `jenkins` user to the `docker` group on Instance 3, explicitly recognizing this as root-equivalent access on the CI/CD host.
- **Mitigation:**
  - The CI/CD instance is dedicated solely to Jenkins and Docker execution (no sensitive customer data or private keys stored).
  - Jenkins port 8080 is private and inaccessible from the internet.
  - The container execution specifies `--user $(id -u):$(id -g)` to prevent generated reports from becoming root-owned.
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

## ADR 009: Backend–Jenkins Asynchronous Polling & Artifact Ingestion Contract
- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** Repository analysis involving Git log extraction, deterministic metrics, chart generation, and LLM inference can take 15–60 seconds. A synchronous HTTP request from frontend to backend would time out.
- **Decision:** Implement an asynchronous job triggering and polling pattern:
  1. Frontend submits repository URL to Backend (`POST /api/analyze`).
  2. Backend validates URL, triggers Jenkins pipeline via `POST /job/git-repo-analyzer/buildWithParameters`, and captures the Queue Item location.
  3. Backend returns a `buildId` tracking token to Frontend.
  4. Frontend polls Backend (`GET /api/status/:buildId`).
  5. Backend resolves queue item to build number and polls Jenkins status.
  6. Upon build completion, Backend downloads archived artifacts (`summary.md`, `charts/*.png`, `metrics.json`) from Jenkins and caches them.
  7. Frontend receives completed status and renders reports via `GET /api/reports/:buildId`.
- **Consequences:** Prevents gateway timeouts, provides transparent progress indicators to the user, and decouples frontend rendering from Jenkins latency.

---

## ADR 010: AWS Cost Governance and Explicit Provisioning Approval
- **Date:** 2026-11-18
- **Status:** Approved (Permanent Governance Standard)
- **Context:** Cloud infrastructure provisioning carries financial liability through recurring compute, storage, public IP, and network egress charges. As of the verified November 18, 2026 snapshot, the project account operates under the AWS Free plan with 115 days remaining (expiry March 12, 2027) and an estimated $107.98 in remaining active promotional credits ($94.68 AWS Free Tier, $20.00 Launch EC2). Unmonitored or continuous 24/7 deployment risks rapidly depleting credits and incurring out-of-pocket charges.
- **Decision:** Establish strict cost governance protocols across all autonomous agent actions and human operator workflows:
  1. No AWS infrastructure resource may be provisioned until its estimated cost, Free Tier eligibility, and potential additional charges have been reviewed and explicitly approved by the project owner.
  2. Before provisioning, evaluate EC2 compute, EBS storage, public IPv4 addresses, data transfer, and other applicable charges.
  3. Never assume Free Tier eligibility based solely on an instance family, size, or service category. Verify eligibility against the applicable account offer and AWS region.
  4. Provide cost comparisons and technical justification before requesting approval.
  5. Never execute Terraform apply, create AWS resources, or incur infrastructure charges without explicit approval.
  6. Cost optimization must not silently compromise the approved architecture, security requirements, or minimum workload requirements.
  7. Treat all infrastructure sizes and cost estimates as provisional until explicitly approved.
- **Consequences:** Eliminates accidental cloud billing, enforces transparency before infrastructure mutation, and maintains strict alignment with project owner budget constraints.

---

## ADR 011: On-Demand Infrastructure Lifecycle Strategy (Ephemeral Provisioning & Teardown)
- **Date:** 2026-11-18
- **Status:** Approved
- **Context:** The Git Repository Analyzer is an educational, demonstration, and assessment system. It is not a permanent public web service requiring 24/7 availability. Running three EC2 instances continuously would exhaust account promotional credits unnecessarily.
- **Decision:** Implement an on-demand, ephemeral infrastructure lifecycle:
  1. **Provision on Demand:** Infrastructure is created via `terraform apply` when needed for development, testing, or demonstrations.
  2. **Automated Configuration:** Ansible bootstraps base OS packages and Puppet enrollment; Puppet enforces desired application, NGINX, Jenkins, and Nagios state.
  3. **Demonstrate & Test:** Perform end-to-end repository analysis, review reports, and verify monitoring.
  4. **Destroy Immediately After Use:** When the session concludes, execute `terraform destroy` to terminate all three EC2 instances, release public IPv4 addresses, and destroy attached EBS volumes.
  5. **Stop vs. Destroy Policy:** Stopping instances only halts compute charges while EBS storage and IPv4 reservation charges persist. Complete teardown (`terraform destroy`) is mandatory between demonstration milestones to eliminate compute, storage, and IP idle charges.
  6. **Stateful Data Boundaries:**
     - All infrastructure code, Ansible roles, Puppet code, Dockerfiles, and application code are committed to Git.
     - The S3 remote state bucket (`git-repo-analyzer-terraform-state-2026`) is permanent, independent of instance lifecycle, and must never be destroyed.
     - Analysis reports generated during sessions can be exported or committed prior to teardown.
- **Consequences:** Replaces high 24/7 continuous cloud costs (~$56.39/mo estimated) with minimal estimated session costs (~$0.31 for a 4-hour demonstration, ~$1.24/mo for weekly demos), preserving the majority of the verified $107.98 promotional credit pool (November 18, 2026 snapshot) as a buffer through the March 12, 2027 expiration date. Actual costs remain provisional estimates subject to account-level spend, credit eligibility rules, and additional usage charges.
