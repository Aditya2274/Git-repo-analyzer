# Implementation Plan: Git Repository Analyzer

This document defines the dependency-aware, phased implementation roadmap for the Git Repository Analyzer project. Each phase contains clear prerequisites, actionable subtasks, completion criteria, and verification steps.

---

## Roadmap Overview

```
Phase 1: Inspection & Alignment (Done)
   │
   ▼
Phase 2: Analyzer Script Fixes & Container Validation (Done)
   │
   ▼
Phase 3: Terraform Multi-Instance Infrastructure & Networking
   │
   ▼
Phase 4: Ansible Bootstrap & Puppet Master/Agent Enrollment
   │
   ▼
Phase 5: Puppet Continuous Configuration Management (NGINX, Services, Nagios, NRPE)
   │
   ▼
Phase 6: Application Development (Express Backend API & React Frontend UI)
   │
   ▼
Phase 7: Jenkins Pipeline Configuration & Backend Integration
   │
   ▼
Phase 8: Monitoring Configuration & End-to-End System Verification
```

---

## Phase 1: Inspection & Documentation (Completed)
- **Objective:** Inspect existing codebase, verify live AWS state, and establish unified project governance.
- **Status:** Complete. `AGENTS.md` and all `project_docs/` populated.

---

## Phase 2: Analyzer Script Bug Fixes & Container Validation (Completed)
- **Objective:** Fix verified bugs in `analyze2.sh` and ensure full zero-commit and interactive support before deploying or rebuilding containers.
- **Status:** Complete (2026-11-18).
- **Subtasks Completed:**
  1. Restored missing functions `show_menu` and `show_commit_summary` in `analyze2.sh`.
  2. Implemented robust zero-commit detection (`git rev-parse HEAD >/dev/null 2>&1`) and correctly initialized `ZERO_COMMITS=true/false` before metric calculations.
  3. Validated non-interactive mode (`[ ! -t 0 ]`) passes `ZERO="$ZERO_COMMITS"` accurately to `ai/reportGenerator.js`.
  4. Built local Docker image `git-repo-analyzer:phase2-test` from `Dockerfile`.
  5. Tested Docker container execution against a repository with commits (verified `metrics.json`, `summary.md`, `commits_per_author.png`, `daily_commit_activity.png`).
  6. Tested Docker container execution against an empty repository with zero commits (verified clean handling without Git `HEAD` errors).
  7. Tested interactive execution in Docker via pseudo-terminal covering menu options 1, 2, 3, and 4.
- **Verification Evidence:** All tests exited with code 0. Reports, metrics, and charts were validated.

---

## Phase 3: Terraform Multi-Instance Infrastructure & Networking (Completed)
- **Objective:** Define reproducible Terraform configuration for the three dedicated EC2 instances and multi-tier security groups, designed for on-demand provisioning and complete teardown (`terraform apply` $\rightarrow$ demo $\rightarrow$ `terraform destroy`) while preserving the existing S3 backend and enforcing strict cost governance.
- **Status:** **Completed (Implementation & Validation Committed in `3dc7870`)**. Live provisioning operates strictly on-demand.
- **Prerequisites:** Phase 2 completion, human review and written approval of instance sizing, storage allocation, and projected on-demand session costs.
- **Subtasks Completed:**
  1. Preserved persistent S3 remote backend block in `terraform/main.tf` with `use_lockfile = true` (bucket `git-repo-analyzer-terraform-state-2026`).
  2. Implemented approved three-instance EC2 architecture in `modules/ec2`:
     - `puppet_server`: `t3.small` (2 vCPU, 2 GB RAM), 15 GB gp3 EBS root volume, tagged `Role = puppet-server`.
     - `app_monitoring`: `t3.micro` (2 vCPU, 1 GB RAM), 15 GB gp3 EBS root volume, tagged `Role = app-monitoring`.
     - `cicd_analysis`: `t3.small` (2 vCPU, 2 GB RAM), 20 GB gp3 EBS root volume, tagged `Role = cicd-analysis`.
     - Fleet Storage Total: Exactly 50 GB gp3 across all 3 nodes.
     - Dynamic AMI lookup using Ubuntu 24.04 LTS SSM Parameter Store.
  3. Implemented outbound internet access & directional security groups:
     - Explicitly configured `associate_public_ip_address = true` on all 3 instances within Default VPC public subnets (direct outbound connectivity without an expensive NAT Gateway).
     - Ingress strictly locked: SSH (port 22) to operator CIDR; Puppet (port 8140) restricted to EC2 2 & EC2 3 SGs; Jenkins API (port 8080) restricted to EC2 2 SG; NRPE (port 5666) restricted to EC2 2 SG on both EC2 1 and EC2 3; public HTTP/HTTPS (80/443) on EC2 2 only.
  4. Updated `terraform/output.tf` and `modules/ec2/outputs.tf` to expose instance IDs, public/private IPs, DNS, and dynamically generated Ansible inventory.
  5. Validated configuration cleanly with `terraform fmt -check`, `terraform validate`, and `git diff --check`. Committed in `3dc78707a0329774152137fac6a225970793ef3d` on branch `feat/terraform-infrastructure`.
- **Governance & Non-Actions:**
  - `terraform apply` has **NOT** been executed; zero live AWS resources have been provisioned or mutated.
  - The S3 state bucket is persistent infrastructure and must not be destroyed with the ephemeral EC2 fleet.
  - Live provisioning operates strictly on-demand and remains blocked until explicit operator authorization prior to demonstrations.
- **Completion Criteria:**
  - Three EC2 instances defined in modular, reproducible HCL.
  - Internal management ports (8140, 8080, 5666) completely unreachable from the public internet.
  - Outbound internet enabled via public IPv4 association.
  - Terraform state cleanly maintained in remote S3 bucket.
  - Code validated and committed to repository.

---

## Phase 4: Ansible Bootstrap & Puppet Master/Agent Setup
- **Objective:** Bootstrap base operating systems and establish Puppet CA trust and agent enrollment across all three instances.
- **Prerequisites:** Phase 3 infrastructure provisioned.
- **Subtasks:**
  1. Configure `ansible/inventory/hosts.ini` with groups: `[puppet_server]`, `[app_monitoring]`, `[cicd_analysis]`.
  2. Author `roles/puppet_server`:
     - Installs Puppet 8 release package and `puppetserver`.
     - Configures JVM heap in `/etc/default/puppetserver` to `-Xms1g -Xmx1g`.
     - Starts and enables `puppetserver` service.
     - Configures explicit, controlled certificate signing workflow (autosigning is prohibited).
  3. Author `roles/puppet_agent`:
     - Installs `puppet-agent` on Instances 2 and 3.
     - Configures `server = <puppet-server-private-ip>` in `/etc/puppetlabs/puppet/puppet.conf`.
     - Initiates agent CSR to Puppet Server.
  4. Extend `roles/docker` to install Docker CE on Instance 3 and add `jenkins` and `ubuntu` to the `docker` group.
  5. Apply `roles/common` across all nodes.
  6. Perform controlled verification and signing of agent CSRs on Puppet Server: inspect pending CSRs and fingerprints with `puppetserver ca list`, verify host identities against inventory, and sign each cert explicitly (`puppetserver ca sign --certname <agent-name>`). Bulk signing (`--all`) is prohibited.
- **Completion Criteria:**
  - Puppet Server active with tuned 1 GB JVM heap.
  - Both agents enrolled with signed SSL certificates.
  - `puppet agent -t` executes successfully on both agent nodes.

---

## Phase 5: Puppet Continuous Configuration Management
- **Objective:** Author Puppet manifests and modules to enforce desired state on Application and CI/CD servers.
- **Prerequisites:** Phase 4 completion (Puppet agents communicating with master).
- **Subtasks:**
  1. Create Puppet module for **Application Server (`app_monitoring`)**:
     - Manages NGINX installation and virtual host reverse-proxying frontend and backend.
     - Manages Node.js 20 LTS runtime.
     - Configures systemd service unit for backend API.
     - Installs Nagios Core, compiles plugins, and sets up `/etc/nagios/` host and service definitions.
  2. Create Puppet module for **CI/CD Server (`cicd_analysis`)**:
     - Installs and configures NRPE daemon (`/etc/nagios/nrpe.cfg`).
     - Restricts `allowed_hosts` in `nrpe.cfg` to the Application Server's private IP.
     - Deploys NRPE check scripts (check_disk, check_docker, check_procs).
- **Completion Criteria:**
  - Puppet catalog compiles and applies cleanly on both nodes without errors.
  - NGINX is running on Instance 2.
  - NRPE daemon is running on Instance 3 and responds to `check_nrpe` from Instance 2.

---

## Phase 6: Application Development (Backend API & Frontend UI)
- **Objective:** Develop the Node.js/Express backend API and the React/Vite single-page application.
- **Prerequisites:** Phase 5 completion.
- **Subtasks:**
  1. **Backend Development (`backend/`):**
     - Initialize Node.js Express service.
     - Implement `POST /api/analyze` (URL validation, repository sanity check).
     - Implement Jenkins API service: triggers parameterized pipeline job via authenticated HTTP POST, parses queue item, and tracks build number.
     - Implement `GET /api/status/:buildId`: returns active build status.
     - Implement `GET /api/reports/:buildId`: fetches archived artifacts (`summary.md`, `charts/*.png`, `metrics.json`) from Jenkins and returns formatted payload.
  2. **Frontend Development (`frontend/`):**
     - Scaffold React application using Vite.
     - Implement repository submission form with client-side input validation.
     - Implement polling hook for active build status (Queued $\rightarrow$ Cloning $\rightarrow$ Analyzing $\rightarrow$ Completed).
     - Implement report viewer rendering Markdown with embedded Chart.js PNG images and metric scorecards.
- **Completion Criteria:**
  - Backend API unit tests pass.
  - Frontend builds cleanly (`npm run build`).
  - NGINX serves frontend static assets and proxies `/api` calls to Express.

---

## Phase 7: Jenkins Pipeline Configuration & Backend Integration
- **Objective:** Provision Jenkins on Instance 3, configure pipeline job, and verify end-to-end backend integration.
- **Prerequisites:** Phase 6 completion.
- **Subtasks:**
  1. Install Jenkins on Instance 3, configure initial administrator credentials and API token.
  2. Store `GROQ_API_KEY` in Jenkins Credentials Store as secret text (`credentialsId: 'groq-api-key'`).
  3. Create pipeline job `git-repo-analyzer` loaded with `Jenkinsfile`.
  4. Ensure Jenkins user can execute `docker` commands without sudo.
  5. Test end-to-end execution: submit URL from Frontend $\rightarrow$ Backend triggers Jenkins $\rightarrow$ Docker container analyzes repo $\rightarrow$ Reports archived $\rightarrow$ Backend retrieves artifacts $\rightarrow$ Frontend displays report.
- **Completion Criteria:**
  - Jenkins executes pipeline successfully inside Docker container.
  - Artifacts (`summary.md`, `commits_per_author.png`, `daily_commit_activity.png`) are archived and retrieved via API.
  - Frontend displays completed report and visual charts.

---

## Phase 8: Monitoring Configuration & End-to-End System Verification
- **Objective:** Configure Nagios Core monitoring, verify NRPE telemetry, and perform full disaster recovery and convergence testing.
- **Prerequisites:** Phase 7 completion.
- **Subtasks:**
  1. Configure Nagios host definitions on Instance 2 for:
     - Instance 1 (Puppet Server): ping, SSH, port 8140 health.
     - Instance 2 (Application Server): ping, SSH, NGINX process, Express API process, disk usage.
     - Instance 3 (CI/CD Server): ping, SSH, NRPE checks (Docker daemon, disk space, Jenkins service).
  2. Verify administrative access to Nagios web interface over SSH tunnel (`localhost:8080/nagios`).
  3. Trigger configuration drift test: modify NGINX config manually on Instance 2, verify Puppet run reverts changes.
  4. Perform end-to-end acceptance test analyzing public repositories (standard repo, high-churn repo, zero-commit repo).
- **Completion Criteria:**
  - All Nagios services report `OK` status.
  - Puppet catalog enforces desired state without manual intervention.
  - System fully documented and ready for production operations.
