# AGENTS.md — Git Repository Analyzer Project Source of Truth

This document is the permanent primary source of truth, architectural standard, and governance specification for the **Git Repository Analyzer** project. All human operators, autonomous agents, and tool integrations must adhere to the decisions, constraints, patterns, and workflows defined herein.

---

## 1. Project Overview & Architecture

The objective of this project is to provide an enterprise-grade, automated system that accepts arbitrary Git repository URLs, analyzes their code health, contributor dynamics, code churn, and architectural posture using deterministic metrics and Groq LLM inference, renders visual activity charts, and displays actionable reports via a modern web interface.

The approved production architecture consists of **exactly three dedicated AWS EC2 instances**:

```
                                  [ Operator CIDR ]
                                          │
                                    (SSH: Port 22)
                                          │
                                          ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │                                AWS VPC                                      │
   │                                                                             │
   │   ┌────────────────────────┐         ┌──────────────────────────────────┐   │
   │   │     Puppet Server      │         │ Application + Monitoring Server  │   │
   │   │  (Instance 1: t3.small)│         │     (Instance 2: t3.small)       │   │
   │   │                        │         │                                  │   │
   │   │ • Puppet Server 8      │         │ • React Frontend (Vite / Build)  │   │
   │   │ • Puppet CA            │◄──8140──│ • Node.js / Express Backend API  │   │
   │   │ • Puppet Agent         │         │ • NGINX Reverse Proxy (80 / 443) │   │
   │   │                        │         │ • Nagios Core Monitoring         │   │
   │   └────────────────────────┘         │ • Puppet Agent                   │   │
   │                ▲                     └──────────────────────────────────┘   │
   │                │                                  │        │                │
   │              8140                               8080      5666              │
   │                │                           (Jenkins API) (NRPE)             │
   │                │                                  ▼        ▼                │
   │   ┌─────────────────────────────────────────────────────────────────────┐   │
   │   │                    CI/CD + Analysis Server                          │   │
   │   │                     (Instance 3: t3.medium)                         │   │
   │   │                                                                     │   │
   │   │ • Jenkins Controller (Port 8080 — Internal Only)                    │   │
   │   │ • Docker Engine & Compose                                           │   │
   │   │ • Dockerized Git Repository Analyzer Container                      │   │
   │   │ • NRPE Monitoring Daemon (Port 5666 — Internal Only)                │   │
   │   │ • Puppet Agent                                                      │   │
   │   └─────────────────────────────────────────────────────────────────────┘   │
   └─────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Dedicated Server Roles
1. **Puppet Server (Instance 1):**
   - Role: Dedicated Central Configuration Management & Certificate Authority (CA).
   - Components: Puppet Server (v8.x), Puppet CA, internal Puppet code repository, Puppet Agent.
2. **Application + Monitoring Server (Instance 2):**
   - Role: User-facing application delivery, API orchestration, and infrastructure monitoring.
   - Components: React Single Page Application (SPA), Node.js / Express REST API, NGINX Reverse Proxy, Nagios Core monitoring server, Puppet Agent.
3. **CI/CD + Analysis Server (Instance 3):**
   - Role: Isolated operational pipeline execution, containerized code analysis, and system health telemetry.
   - Components: Jenkins Automation Controller, Docker CE Engine, Dockerized Git Repository Analyzer (`adityaashok2274/git-repo-analyzer:latest`), Nagios Remote Plugin Executor (NRPE) daemon, Puppet Agent.

---

## 2. Infrastructure & Networking Standards (Terraform)

### 2.1 S3 Remote State Backend Preservation
- The Terraform S3 remote backend configuration defined in `terraform/main.tf` is **permanent and must be preserved without modification, destruction, or recreation**:
  ```hcl
  terraform {
    backend "s3" {
      bucket       = "git-repo-analyzer-terraform-state-2026"
      key          = "git-repo-analyzer/terraform.tfstate"
      region       = "ap-south-1"
      encrypt      = true
      use_lockfile = true
    }
  }
  ```
- State locking utilizes Terraform 1.10+ native S3 lockfiles (`use_lockfile = true`). No DynamoDB table is required.

### 2.2 Provisional Instance & Storage Sizing (On-Demand Model)
Infrastructure sizing decisions are **strictly provisional, unapproved, and subject to explicit cost review and written operator authorization** before Terraform provisioning. The architecture operates under an **on-demand demonstration lifecycle** (provisioned when needed, destroyed after demonstration/testing):
- **Puppet Server:** Provisional candidate: `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS). The default vendor JVM heap (`-Xms2g -Xmx2g`) **must be tuned down** to `-Xms1g -Xmx1g` (or `-Xms512m -Xmx512m`) in `/etc/default/puppetserver` to comfortably fit within 2 GB RAM for a two-agent fleet.
- **Application + Monitoring Server:** Provisional candidate: `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS). Steady-state memory footprint (NGINX + Node.js Express + Nagios Core C-daemon + periodic Puppet Agent) is ~420 MB, fitting comfortably within 1 GB RAM. Eligible under the AWS Free plan.
- **CI/CD + Analysis Server:** Provisional candidate: `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS). With Jenkins controller JVM tuned to `-Xms384m -Xmx512m`, concurrent execution of Jenkins, Docker daemon, and the containerized analyzer requires ~1,232 MB RAM at peak, leaving ~816 MB headroom on a 2 GB instance. A 1–2 GB swapfile acts as a supplementary safety cushion. Sized with 20 GB gp3 storage to accommodate Jenkins home, Docker image cache (`git-repo-analyzer`), build artifacts, and cloned workspaces.
- **Fleet Storage Allocation:** Exactly 50 GB gp3 across the fleet (15 GB Puppet + 15 GB App/Monitoring + 20 GB CI/CD).
- **Storage & Outbound Internet Strategy:** 
  - All three instances are allocated in the public subnet with Public IPv4 addresses to provide direct, low-cost outbound internet connectivity (package repositories, Docker Hub, Jenkins plugins, GitHub, Groq API). This avoids the heavy recurring cost of an AWS NAT Gateway ($0.056/hr = ~$40.88/mo) and the operational failure risks of a NAT instance.
  - Public IPv4 charges ($0.005/hr per instance) are incurred only while instances are running during on-demand sessions (e.g., $0.06 total for a 4-hour demonstration across all 3 instances).
  - All internal services (Jenkins 8080, Puppet 8140, NRPE 5666) are strictly blocked from public ingress via directional security groups.

### 2.3 Strict Directional Security Group Rules
No internal management port may ever be exposed to `0.0.0.0/0`. Security groups must reference peer security group IDs:

1. **`sg_puppet_server`:**
   - Ingress TCP `8140`: Restricted strictly to `sg_app_monitoring` and `sg_cicd_analysis`. (No public access).
   - Ingress TCP `22`: Restricted to `var.allowed_ssh_cidr` (operator only).
   - Egress: Outbound all (for apt and Puppet package repositories).
2. **`sg_app_monitoring`:**
   - Ingress TCP `80`, `443`: Allowed from `0.0.0.0/0` (public access to frontend and authenticated reverse proxy).
   - Ingress TCP `22`: Restricted to `var.allowed_ssh_cidr` (operator only).
   - Internal API ports (`3000` / `5000`): Bound to `127.0.0.1` locally; **not** exposed in SG ingress.
   - Egress: Outbound all.
3. **`sg_cicd_analysis`:**
   - Ingress TCP `8080` (Jenkins): Restricted strictly to `sg_app_monitoring` (allowing the Express backend to trigger jobs and query build artifacts). **No public or operator-CIDR ingress.**
   - Ingress TCP `5666` (NRPE): Restricted strictly to `sg_app_monitoring` (allowing Nagios to execute remote checks). **No public access.**
   - Ingress TCP `22`: Restricted to `var.allowed_ssh_cidr` (operator only).
   - Egress: Outbound all (for Docker Hub pulls, GitHub cloning, Groq API, Jenkins updates).

### 2.4 Administrative Access & SSH Tunneling
- **Nagios Administration:** Public HTTP/HTTPS must serve the user application only. Nagios administration (`/nagios`) must never be exposed publicly. Administrative access must be restricted to an SSH tunnel (e.g., `ssh -L 8080:localhost:80 ...` or `127.0.0.1` binding with NGINX IP whitelisting).
- **Jenkins Administration:** Because port 8080 is private to the Application Server SG, operator UI access to Jenkins must be conducted via SSH port forwarding (`ssh -L 8081:localhost:8080 -i key.pem ubuntu@<cicd-ip>`).

### 2.5 On-Demand Infrastructure Lifecycle & Reproducibility
The three EC2 instances are **temporary, ephemeral demonstration infrastructure**. They are not permanent 24/7 cloud workloads:
1. **Lifecycle Workflow:**
   $$\text{terraform apply} \longrightarrow \text{Ansible Bootstrap} \longrightarrow \text{Puppet Enforce} \longrightarrow \text{Application Deploy} \longrightarrow \text{Demonstrate} \longrightarrow \text{terraform destroy}$$
2. **Stop vs. Destroy Standard:**
   - When a session ends, the infrastructure must be terminated using `terraform destroy` to release compute, storage, and IPv4 resources completely.
   - Stopping instances halts compute charges but continues accruing EBS storage and static IP charges. Therefore, full teardown (`terraform destroy`) is the approved baseline.
3. **Stateful Data Boundaries:**
   - All code, configurations, Ansible playbooks, and Puppet manifests must be preserved in version control (Git).
   - The Terraform S3 remote state backend (`git-repo-analyzer-terraform-state-2026`) is permanent, independent of instance lifecycle, and must never be destroyed.
   - Re-provisioning through `terraform apply` and re-running Ansible/Puppet must automatically restore all services, certificates, and configurations from scratch without manual intervention.

---

## 3. Configuration Management & Automation Separation

To prevent resource conflict and configuration drift, automation responsibilities are strictly partitioned between Ansible and Puppet:

### 3.1 Ansible: Day 0 / Day 1 Bootstrap
Ansible is the initial provisioning and bootstrapping orchestrator. Once an instance is provisioned by Terraform, Ansible executes:
1. Base OS setup, system updates, and installation of baseline utilities via `roles/common` (`curl`, `git`, `unzip`, `ca-certificates`).
2. Installation of Docker CE and Compose on the CI/CD server via `roles/docker`.
3. Installation of the official Puppet 8 repository and `puppetserver` package on Instance 1.
4. Tuning of Puppet Server JVM memory parameters (`-Xms1g -Xmx1g`).
5. Installation of `puppet-agent` on Instances 2 and 3, setting `server = <puppet-server-fqdn/ip>` in `/etc/puppetlabs/puppet/puppet.conf`, and triggering certificate signing requests (CSR). On the Puppet Server, CSRs must be inspected via `puppetserver ca list` and verified against host identities, followed by explicit per-certname signing (`puppetserver ca sign --certname <agent-name>`); indiscriminate bulk signing (`--all`) and blind autosigning are strictly disallowed.

### 3.2 Puppet: Day 2+ Continuous Configuration Management
Once Puppet agents are enrolled, Puppet owns all desired-state configuration and ongoing enforcement:
1. **Application Server State:**
   - NGINX installation, virtual host configurations, and SSL certificates.
   - Node.js runtime environment and backend systemd service definition (`git-repo-analyzer-api.service`).
   - Nagios Core package installation, daemon configuration, contact definitions, host definitions, and service check commands.
2. **CI/CD Server State:**
   - NRPE daemon package installation, `/etc/nagios/nrpe.cfg` configuration, and plugin scripts.
   - System users, permissions, and directory structures.
3. **Drift Prevention:** Periodic runs (every 30 minutes) ensure manual changes are automatically remediated. Ansible never touches application configuration files managed by Puppet.

---

## 4. Application Subsystems & Integration Workflow

### 4.1 Git Repository Analyzer Subsystem
- **Core Script (`analyze2.sh`):**
  - Must support both interactive terminal execution (`show_menu`, `show_commit_summary`) and non-interactive Docker/CI execution (`run_full_analysis`).
  - Zero-commit detection (`git rev-list --count HEAD`) must be explicitly evaluated and stored in `ZERO_COMMITS` before executing metric commands, avoiding crashes on empty repositories.
- **Deterministic Metrics (`ai/metrics.js`):**
  - Bus Factor: Implements Degree of Authorship (DOA) formula:
    $$\text{DOA}(e,f) = 3.293 + 1.098(\text{FA}) + 0.164(\text{DL}) - 0.321\ln(1 + \text{AC})$$
  - Code Churn & Hotspots: Exponential decay churn scoring ($\lambda = 0.05$) over 30 days.
  - Branch Drift: Measures unmerged divergence days and drift scores.
  - Generates `reports/metrics.json`.
- **Visual Visualizations (`ai/chartGenerator.js`):**
  - Generates `reports/charts/commits_per_author.png` (bar chart).
  - Generates `reports/charts/daily_commit_activity.png` (line chart).
- **AI Architectural Review (`ai/reportGenerator.js`, `ai/prompt.js`, `ai/providers/groqProvider.js`):**
  - Interprets deterministic metrics using Groq LLM (`groq/compound-mini`).
  - **Static Fallback:** If `GROQ_API_KEY` is unset or API invocation fails, automatically outputs a complete static Markdown report (`reports/summary.md`) without error.

### 4.2 CI/CD Execution Model
- **Analyzer Image CI (GitHub Actions):** Defined in `.github/workflows/docker-ci.yml`. On push to `main`, builds the Docker image, tests it, and publishes versioned and `latest` tags to Docker Hub (`adityaashok2274/git-repo-analyzer`).
- **Operational Analysis Pipeline (Jenkins):** Defined in `Jenkinsfile`. Runs on Instance 3:
  1. Pulls `adityaashok2274/git-repo-analyzer:latest` from Docker Hub.
  2. Clones the target repository supplied via build parameter `REPO_URL`.
  3. Mounts the target repo into `/repo` inside the analyzer container with `--user $(id -u):$(id -g)`.
  4. Injects `GROQ_API_KEY` from Jenkins credentials store.
  5. Archives `target-repo/reports/**/*`.

### 4.3 Backend $\rightarrow$ Jenkins Integration Flow
- **Express Backend Responsibilities:**
  1. `POST /api/analyze`: Validates Git repository URL, sends authenticated HTTP POST to Jenkins REST API (`POST http://<cicd-private-ip>:8080/job/git-repo-analyzer/buildWithParameters?REPO_URL=<url>`).
  2. Captures Jenkins queue item location header, polls queue until build number is assigned.
  3. Polls build status (`/job/git-repo-analyzer/<build_number>/api/json`) until completion.
  4. Downloads archived artifacts (`summary.md`, `metrics.json`, `charts/*.png`) from Jenkins artifact endpoints and caches them.
  5. `GET /api/reports/:id`: Serves structured analysis data and report content to the frontend.

### 4.4 Frontend UI Responsibilities
- React Single Page Application (Vite-based):
  1. Input view: Form for submitting Git URLs with validation.
  2. Live progress tracker: Visual indicator showing Queued $\rightarrow$ Cloning $\rightarrow$ Analyzing $\rightarrow$ Completed.
  3. Report presentation view: Renders `summary.md` with embedded Chart.js PNG visualizations and deterministic risk badges (Bus Factor, Hotspots, Drift).

---

## 5. Security & Secret Management Requirements

1. **Private Keys:**
   - The RSA private key `git-repo-analyzer.pem` must be moved to `~/.ssh/` and deleted from the repository workspace to avoid accidental exposure. Permissions must remain `0400`.
2. **Jenkins Docker Group Trade-Off:**
   - Adding the `jenkins` user to the `docker` group grants root-equivalent privileges on Instance 3. This is an accepted engineering trade-off for containerized analysis, but requires that the Jenkins instance remain strictly internal, unexposed to public networks, and accessible only by the Backend service account.
3. **No Embedded Secrets:**
   - API tokens (`GROQ_API_KEY`, Docker Hub tokens, Jenkins API tokens) must never be committed to Git, hardcoded in scripts, or baked into Docker images.
   - Secrets must be injected via Jenkins credential store or systemd environment files (`chmod 0600`).
4. **Terraform Variables:**
   - `terraform.tfvars` must remain in `.gitignore`. No credentials or public IPs shall be committed to version control.

---

## 6. Implementation Guardrails & Agent Rules

1. **Strict Phased Progression:** Implementation must proceed sequentially through the approved stages. Never jump ahead to coding or provisioning without explicit approval.
2. **Preserve Working Code:** Existing working implementations—including the S3 backend, the Dockerfile graphics stack, the deterministic metrics engine, and the GitHub Actions CI—must be preserved and extended, not rewritten from scratch.
3. **Verification Before Assertion:** Never declare that a feature works or exists without verifying it through direct file inspection or read-only CLI commands. Distinguish clearly between *implemented*, *configured*, *tested*, and *verified*.
4. **Explicit Infrastructure Approval:** No Terraform apply, destroy, or AWS resource provisioning may ever be executed without prior human operator review and explicit written authorization.

---

## 7. Infrastructure Cost Governance & Provisioning Approval

1. No AWS infrastructure resource may be provisioned until its estimated cost, Free Tier eligibility, and potential additional charges have been reviewed and explicitly approved by the project owner.
2. Before provisioning, evaluate EC2 compute, EBS storage, public IPv4 addresses, data transfer, and other applicable charges.
3. Never assume Free Tier eligibility based solely on an instance family, size, or service category. Verify eligibility against the applicable account offer and AWS region.
4. Provide cost comparisons and technical justification before requesting approval.
5. Never execute Terraform apply, create AWS resources, or incur infrastructure charges without explicit approval.
6. Cost optimization must not silently compromise the approved architecture, security requirements, or minimum workload requirements.
7. Treat all infrastructure sizes and cost estimates as provisional until explicitly approved.
