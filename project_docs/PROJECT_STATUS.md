# Project Status: Git Repository Analyzer

**Current Phase:** Phase 3 Complete (Terraform Multi-Instance Infrastructure & Networking Implemented & Validated in Code; Live AWS Provisioning Pending)
**Next Phase:** Phase 4 (Ansible Bootstrap & Puppet Master/Agent Setup — Planning & Review Complete, Awaiting Deployment Authorization)
**Last Updated:** 2026-11-22
**Repository Branch:** `feat/terraform-infrastructure`

---

## 1. Executive Status Summary

The project has completed Phase 1 (inspection & verification), Phase 2 (analyzer script repairs & local container validation), and Phase 3 (Terraform multi-instance infrastructure & networking code implementation).

Phase 3 implementation was completed, validated, and committed to branch `feat/terraform-infrastructure` in commit `3dc78707a0329774152137fac6a225970793ef3d`. The Terraform configuration defines the complete three-node architecture:

- Dedicated Puppet Server (`t3.small`, 15 GB gp3 root volume).
- Application and Monitoring Server (`t3.micro`, 15 GB gp3 root volume).
- CI/CD and Analysis Server (`t3.small`, 20 GB gp3 root volume).
- Total fleet storage: Exactly 50 GB gp3.
- Dynamic Ubuntu 24.04 LTS AMI lookup via AWS SSM Parameter Store.
- Explicit public IPv4 association (`associate_public_ip_address = true`) across all three nodes within the Default VPC and public subnets, providing direct outbound connectivity without an expensive NAT Gateway.
- Strict least-privilege security groups: public HTTP/HTTPS (ports 80/443) on EC2 2 only; SSH (port 22) restricted to operator CIDR /32; internal management ports strictly cross-referenced via security groups (Puppet 8140 from EC2 2 and EC2 3 to EC2 1; Jenkins 8080 from EC2 2 to EC2 3; NRPE 5666 from EC2 2 to both EC2 1 and EC2 3).
- Outputs expose instance IDs, public/private IPs, DNS names, and canonical Ansible inventory output (`ansible_inventory_template`).

**Operational Governance & Non-Actions:**

- `terraform apply` has **NOT** been executed. Zero AWS resources have been provisioned or mutated.
- The infrastructure deployment model is strictly **on-demand and ephemeral** (`terraform apply` $\rightarrow$ setup/demo $\rightarrow$ `terraform destroy`). The instances will NOT run continuously (24/7).
- Operating under this on-demand lifecycle limits estimated demonstration costs to ~$0.31 (4 hours) or ~$1.24/month for weekly demos (fleet running rate ~$0.0773/hour across 50 GB gp3 storage, 3 public IPv4 addresses, and 3 EC2 instances). Actual costs remain provisional estimates subject to account-level spend, credit eligibility rules, and additional usage charges.
- The persistent S3 remote state backend (`git-repo-analyzer-terraform-state-2026`, `ap-south-1`, `use_lockfile = true`) remains intact and unmodified. No remote state object is written to S3 until `terraform apply` is executed.
- Older historical single-instance designs or alternative sizing proposals are superseded.

---

## 2. Component Implementation Status

| Component                          |                           Status                           | Verified Capabilities / Implementation Details                                                                                                                                                                                                                                                                                                                                                                                                                      | Gaps & Next Implementation Steps                                                                                                                                                                                      |
| :--------------------------------- | :--------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Terraform & AWS**          | **Implemented & Validated (Provisioning On-Demand)** | Three-node EC2 architecture defined in `modules/ec2`. 50 GB gp3 storage allocated (15+15+20). Directional SGs implemented with inter-SG cross-references (SSH on 22, Web on 80/443, Puppet on 8140, Jenkins on 8080, NRPE on 5666). Public IPv4 associated on all instances. Dynamic Ansible inventory output created. S3 backend intact with native state locking. Validated with `terraform validate` and `terraform fmt -check`. Committed in `3dc7870`. | Live provisioning pending explicit operator authorization (`terraform apply` has not been run).                                                                                                                     |
| **Ansible Bootstrap**        | **In Progress (Checkpoints 4.1–4.4 Audited & Validated)** | Canonical inventory (`[puppet_server]`, `[application]`, `[cicd]`, `[puppet_agents:children]`) implemented. Deterministic SSH trust (`verify_ssh_host_keys.sh`, 8/8 tests passed) and inventory sync (`sync_terraform_inventory.sh`, 5/5 tests passed) complete. Common role (`roles/common`) enhanced with safe non-destructive APT POSIX record lock wait using Python `fcntl.lockf`, essential packages, timezone/NTP sync, `/etc/hosts` private DNS, and per-instance swap allocation with 9 safety and lifecycle scenarios (16/16 tests passed). Dedicated Puppet Server role (`roles/puppet_server`) implemented with Ubuntu 24.04 noble repository + fallback package handling, vendor APT pinning (`origin apt.puppet.com` @ 900) over distro universe (500), JVM heap tuning (-Xms1g -Xmx1g), max-active-jrubies: 1, puppet.conf stable identity (puppet-server, puppet) with autosign=false, 3-state cryptographic CA validation (State A setup, State B modulus match skip, State C fail fast), and TCP 8140 service management (20/20 tests passed). Dedicated Puppet Agent role (`roles/puppet_agent`) implemented with official Noble vendor package, APT priority 900 pinning, stable identities (`app-server` on EC2 2, `cicd-server` on EC2 3), `server = puppet-server`, `runinterval = 30m`, DNS/port preflight, and SSL conflict detection. Audited and corrected with two invariants: (1) Agent service daemon defaults to stopped (`puppet_agent_service_state: "stopped"`, `enabled: true`) with handler guards to prevent background polling race conditions and uncontrolled catalog application before Checkpoint 4.5; (2) Strict reachability requirement by default (`puppet_agent_require_server_reachable: true`) failing fast on unreachable TCP 8140, distinguishing remote submission (`puppet ssl submit_request`, failing fast on rc != 0) from offline local generation (`puppet ssl generate_request`), eliminating false "pending CA approval" notices (35/35 tests passed). Total test suite: 84/84 PASS across all 5 suites. | Live EC2 execution pending infrastructure provisioning under Boundary B. Checkpoint 4.5 (Puppet CA Verification & Strict CSR Enrollment) is the next implementation checkpoint. |
| **Puppet Foundations**       |                **Planned (Phase 5A)**                | Module and manifest directory structure designed.                                                                                                                                                                                                                                                                                                                                                                                                                   | Needs base package modules, NRPE daemon module on EC2 1 & EC2 3, and Nagios build prerequisites on EC2 2. Scheduled for Phase 5A.                                                                                     |
| **Backend API**              |                **Planned (Phase 6)**                | Canonical resource-oriented API specification finalized: `GET /api/health`, `POST /api/analyses`, `GET /api/analyses/:id`, `GET /api/analyses/:id/results`. Zod URL & SSRF validation defined. Mock Jenkins client designed.                                                                                                                                                                                                                                | Express application implementation in `backend/`. Scheduled for Phase 6.                                                                                                                                            |
| **Frontend UI**              |                **Planned (Phase 6)**                | React, TypeScript, Vite, Tailwind CSS, and Recharts architecture designed. Polling hook with backoff specified.                                                                                                                                                                                                                                                                                                                                                     | React SPA implementation in `frontend/`. Scheduled for Phase 6.                                                                                                                                                     |
| **Puppet App Config**        |                **Planned (Phase 5B)**                | Systemd service unit contract (`git-repo-analyzer-backend.service`) and NGINX reverse proxy contract defined.                                                                                                                                                                                                                                                                                                                                                     | Puppet manifests managing Node.js 20 LTS runtime, systemd unit, and NGINX virtual hosts. Scheduled for Phase 5B.                                                                                                      |
| **CI/CD & Jenkins**          |            **Configured (Analyzer Core)**            | `Jenkinsfile` operational workflow defined (pulls Docker image, mounts repo, runs analyzer, archives artifacts). GitHub Actions CI (`docker-ci.yml`) builds and publishes image. SGs allow internal port 8080 from EC2 2.                                                                                                                                                                                                                                       | Dedicated Jenkins server not yet provisioned. Jenkins job not created on controller. Backend API client for live Jenkins triggering not deployed. Scheduled for Phase 7.                                              |
| **Docker**                   |                **Verified & Working**                | `Dockerfile` fully configured with Ubuntu 22.04, Cairo/Pango graphics libraries, Node 20, safe directory permissions, pre-installed npm dependencies. Local test build verified.                                                                                                                                                                                                                                                                                  | Docker CE bootstrap on EC2 3 scheduled for Phase 4.                                                                                                                                                                   |
| **Git Repo Analyzer**        |            **Fully Repaired & Verified**            | Core script (`analyze2.sh`) repaired: interactive menu (`show_menu`, `show_commit_summary`) and `ZERO_COMMITS` initialization restored. Deterministic metrics (`ai/metrics.js`), Chart.js generator (`ai/chartGenerator.js`), Groq prompt (`ai/prompt.js`), and fallback report generator (`ai/reportGenerator.js`) fully operational. Container tested locally against active and empty repositories.                                              | None for the analyzer container core.                                                                                                                                                                                 |
| **Monitoring (Nagios/NRPE)** |  **Network Plumbing Configured (Daemons Planned)**  | Terraform security group rules for TCP 5666 implemented and validated on EC2 1 and EC2 3 (restricted to EC2 2). Architecture specifies Apache loopback on `127.0.0.1:8080`, basic auth, and SSH tunnel access.                                                                                                                                                                                                                                                    | Nagios Core, NRPE daemon, plugins, and Apache loopback configuration are **planned, not yet installed or deployed**. Scheduled for Phases 5A and 8.                                                             |
| **Security & Secrets**       |              **Configured & Specified**              | Directional SGs (IMPLEMENTED); Docker non-root user (TESTED); Jenkins internal isolation (IMPLEMENTED); URL validation & SSRF defense (SPECIFIED); Container hook & script execution restrictions (SPECIFIED); Private key relocated to `~/.ssh/git-repo-analyzer.pem` (mode `0400`, outside repository); Project-scoped `ansible/known_hosts` (mode `0600`, git-ignored) and OpenSSH client configuration `ansible/ssh.cfg` enforced. | Live host-key verification and certificate authority initialization pending live EC2 provisioning under Boundary B. |

---

## 3. Verified Working Components (Do Not Re-architect)

1. **Terraform Multi-Instance Codebase (`terraform/`):** Three-instance architecture, directional security groups, 50 GB gp3 storage, dynamic SSM Ubuntu 24.04 AMI, public IPv4 networking, and Ansible inventory generator. Validated via `terraform fmt -check`, `terraform validate`, and `git diff --check` (commit `3dc7870`).
2. **Terraform S3 Remote State Backend:** Verified active in AWS S3 with bucket versioning and AES256 encryption. Native S3 lockfiles enabled (`use_lockfile = true`). Bucket is empty prior to apply.
3. **SSM Parameter AMI Resolution:** Tested dynamic Ubuntu 24.04 LTS AMI retrieval via SSM Parameter Store.
4. **Ansible `common` and `docker` Core Tasks:** Verified task idempotency for base system packages and Docker CE setup.
5. **Analyzer Script (`analyze2.sh`):** Fully restored and verified in Docker for both interactive mode and non-interactive CI mode. Gracefully handles zero-commit repositories without Git errors.
6. **Analyzer Deterministic Algorithms (`ai/metrics.js`):** Validated DOA formula, exponential decay churn, and branch drift calculations.
7. **AI Report Generator Fallback (`ai/reportGenerator.js`):** Confirmed static Markdown report is written successfully when `GROQ_API_KEY` is unavailable.
8. **Docker Build & Graphics Stack (`Dockerfile`):** Confirmed libcairo/libpango dependencies enable headless canvas rendering without X11. Verified by building image `git-repo-analyzer:phase2-test` locally.
9. **GitHub Actions CI (`.github/workflows/docker-ci.yml`):** Fully operational workflow publishing validated images to Docker Hub.

---

## 4. Pre-Deployment Readiness Checklist

Before executing `terraform apply` or provisioning live AWS resources under Boundary B, the following formal checklist must be verified:

- [ ] **1. SSH Operator CIDR**: Variable `var.allowed_ssh_cidr` configured with a strict `/32` subnet matching the operator's verified public IPv4 address.
- [ ] **2. AWS Key Pair**: Key pair named `git-repo-analyzer` exists in region `ap-south-1`.
- [x] **3. Private Key Security & Relocation**:
  - Verified location: `~/.ssh/git-repo-analyzer.pem` (mode `0400`, outside repository).
  - Cleaned from workspace: Confirmed removed from project root workspace and tracked in `.gitignore`.
  - Operational rule: `.gitignore` is not an equivalent security substitute for keeping private keys outside project repositories.
- [ ] **4. Remote State Backend Integrity**: Terraform backend configuration in `terraform/main.tf` verified intact:
  - Bucket: `git-repo-analyzer-terraform-state-2026`
  - Key: `git-repo-analyzer/terraform.tfstate`
  - Region: `ap-south-1`
  - Encryption: `encrypt = true`
  - State Locking: `use_lockfile = true`
  - *(Confirmed: S3 bucket exists and is empty; no remote state object is written until apply is executed. `terraform validate` verifies syntax only, not remote state initialization).*
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
- [ ] **9. Explicit Owner Approval (Boundary B)**: Written authorization received from project owner prior to running `terraform apply`. Approval for Boundary A (Implementation) does not imply approval for Boundary B (AWS Provisioning).

---

## 5. Active Blockers & Prerequisites

- **Approval Boundary Separation**:
  - Phase 4 implementation (authoring Ansible playbooks, roles, syntax tests, and documentation) can proceed under **Approval Boundary A** without provisioning cloud infrastructure.
  - Live AWS Provisioning (executing `terraform apply` and running live Ansible plays against EC2) remains strictly blocked pending **Approval Boundary B** written authorization.
- **Prerequisite for Live AWS Provisioning (Phase 3 Apply):** Explicit operator review and written approval under Boundary B prior to executing `terraform apply`. Requires `var.allowed_ssh_cidr` to be configured and AWS key pair `git-repo-analyzer` present in `ap-south-1`.
- **Prerequisite for Phase 4 Live Execution (Ansible on EC2):** Provisioning of the 3 EC2 instances via `terraform apply` and population of `ansible/inventory/hosts.ini` from Terraform outputs.
- **Prerequisite for Phase 5A (Puppet Foundations):** Functional Puppet Server and CA certificate exchange between Puppet Master and the two agents.
- **Prerequisite for Phase 6 (Application Development):** Phase 5A completion; mock Jenkins client enables local/offline development without live Jenkins.
- **Prerequisite for Phase 5B (Puppet App Configuration):** Phase 6 completion; finalized systemd, NGINX, and environment contracts.
- **Prerequisite for Phase 7 (Jenkins Integration):** Dedicated CI/CD instance provisioned with Jenkins running, pipeline job configured, and API credentials generated.
- **Prerequisite for Phase 8 (Monitoring Completion):** Live applications running on EC2 2 and Jenkins/Docker running on EC2 3.
