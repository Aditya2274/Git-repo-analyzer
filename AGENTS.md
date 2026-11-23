# AGENTS.md

# AI-Powered Git Repository Analyzer

## Permanent Project Instructions and Architecture Specification

---

# 1. PROJECT OVERVIEW

Project name: **AI-Powered Git Repository Analyzer – Automated Contribution and Activity Tracking System**

The objective is to develop and deploy a complete Git Repository Analyzer platform that allows users to submit a public GitHub repository URL and receive:

- Repository contribution statistics.
- Commit activity analysis.
- Author-wise contribution analysis.
- Lines added and removed.
- Most modified files.
- Stale branch detection.
- Activity charts.
- Automated Markdown reports.
- AI-generated repository insights.

The project combines:

- React and Node.js for the application.
- Docker for analyzer execution.
- Jenkins for CI/CD.
- GitHub Actions for existing automation.
- Terraform for AWS infrastructure provisioning.
- Ansible for initial server configuration and bootstrap.
- Puppet for centralized configuration management.
- Nagios Core and NRPE for monitoring.

## Core development principle

**Extend the existing project. Do not rebuild it from scratch.**

The repository already contains working components. Inspect their implementation before modifying anything.

Preserve existing working functionality, interfaces, scripts, configurations, and integrations unless a change is technically necessary.

---

# 2. FINAL INFRASTRUCTURE ARCHITECTURE

The approved architecture consists of exactly THREE EC2 instances:

```text
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
   │   │  (Instance 1: t3.small)│         │     (Instance 2: t3.micro)       │   │
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
   │   │                     (Instance 3: t3.small)                          │   │
   │   │                                                                     │   │
   │   │ • Jenkins Controller (Port 8080 — Internal Only)                    │   │
   │   │ • Docker Engine & Compose                                           │   │
   │   │ • Ephemeral Git Repo Analyzer Container                             │   │
   │   │ • NRPE Monitoring Daemon (Port 5666 — Internal Only)                │   │
   │   │ • Puppet Agent                                                      │   │
   │   └─────────────────────────────────────────────────────────────────────┘   │
   └─────────────────────────────────────────────────────────────────────────────┘
```

Do not introduce additional EC2 instances without explaining the technical necessity and obtaining explicit approval.

Deployment Model: Strict On-Demand Ephemeral Lifecycle (ADR 011). Instances are provisioned for development and demonstrations via `terraform apply` and destroyed via `terraform destroy` when done. Instances do NOT run continuously 24/7. Fleet estimated running cost is ~$0.0773/hour across compute, 50 GB gp3 storage, and 3 public IPv4 addresses (~$0.31 per 4-hour demonstration).

## EC2 1 — Dedicated Puppet Server

Purpose: Centralized configuration management.

Provisional Sizing: `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS). JVM heap tuned down from default `-Xms2g -Xmx2g` to `-Xms1g -Xmx1g` in `/etc/default/puppetserver`.

Components:

- Ubuntu 24.04 LTS.
- Puppet Server.
- Puppet Certificate Authority (CA).

Responsibilities:

- Manage Puppet Agent certificates.
- Receive agent requests.
- Compile Puppet catalogs.
- Distribute configurations.
- Enforce centralized configuration across managed nodes.

Restrictions:

- No Nagios Core.
- No Jenkins.
- No application hosting.
- No Docker workloads.
- No unnecessary services.

This instance must remain dedicated to Puppet Server.

## EC2 2 — Application and Monitoring Server

Purpose: Host the public-facing application and centralized monitoring.

Provisional Sizing: `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS). Steady-state memory footprint is ~420 MB, leaving ~580 MB free RAM.

Components:

- Ubuntu 24.04 LTS.
- NGINX.
- React production build.
- Node.js/Express backend.
- Nagios Core.
- Nagios Plugins.
- Puppet Agent.

Responsibilities:

- Serve the React frontend.
- Handle API requests.
- Communicate with Jenkins over private networking.
- Run NGINX as a reverse proxy.
- Monitor itself and the CI/CD server.
- Run Puppet Agent.

Restrictions:

- Nagios Core must run only here.
- Do not install Puppet Server.
- Do not install Jenkins.

## EC2 3 — CI/CD and Analysis Server

Purpose: Run CI/CD and repository analysis workloads.

Provisional Sizing: `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS). Jenkins JVM tuned to `-Xms384m -Xmx512m` + 1–2 GB swapfile. Storage accommodates Docker image layers, Jenkins home, and workspaces.

Components:

- Ubuntu 24.04 LTS.
- Jenkins.
- Docker Engine.
- Docker Compose plugin.
- Dockerized Git Repository Analyzer.
- NRPE.
- Nagios Plugins.
- Puppet Agent.

Responsibilities:

- Execute Jenkins pipelines.
- Execute Docker-based repository analysis.
- Generate reports and charts.
- Produce artifacts for backend retrieval.
- Respond to Nagios monitoring requests through NRPE.
- Run Puppet Agent.

Restrictions:

- No Nagios Core.
- No Puppet Server.
- Jenkins must not be publicly accessible.
- NRPE must not be publicly accessible.

---

# 3. COMPONENT COMMUNICATION

The application workflow:

1. User opens the public React application.
2. User submits a GitHub repository URL.
3. React sends the request to the Express backend.
4. Backend validates the URL.
5. Backend communicates with Jenkins over the private network.
6. Jenkins triggers the parameterized analysis job.
7. Jenkins executes the Dockerized analyzer.
8. Analyzer generates reports, metrics, and charts.
9. AI integration generates insights.
10. Backend retrieves the results securely.
11. React displays the analysis dashboard.

The frontend must never communicate directly with Jenkins.

## Infrastructure communication

- EC2 1 communicates with EC2 2 and EC2 3 through private networking.
- EC2 2 communicates with Jenkins on EC2 3 through private networking.
- Nagios Core on EC2 2 communicates with NRPE on EC2 3.
- Puppet Agents on EC2 2 and EC2 3 communicate with Puppet Server on EC2 1.

Use private DNS or appropriate private addresses.

Do not hardcode temporary public IP addresses.

---

# 4. NETWORKING AND SECURITY

Implement least-privilege security groups verified against `terraform/modules/ec2/main.tf`.

| Port | Service | Source                          | Destination   | Protocol & Ingress Policy |
| ---- | ------- | ------------------------------- | ------------- | ------------------------- |
| 22   | SSH     | Operator public IP (/32 only)   | EC2 1, 2, 3   | TCP ingress restricted to `var.allowed_ssh_cidr` |
| 80   | HTTP    | Public internet (0.0.0.0/0)     | EC2 2 only    | TCP public web ingress for React frontend |
| 443  | HTTPS   | Public internet (0.0.0.0/0)     | EC2 2 only    | TCP public secure web ingress |
| 8080 | Jenkins | EC2 2 security group only       | EC2 3 only    | TCP ingress restricted to `app_monitoring_sg` |
| 8140 | Puppet  | EC2 2 and EC2 3 security groups | EC2 1 only    | TCP ingress restricted to `app_monitoring_sg` and `cicd_analysis_sg` |
| 5666 | NRPE    | EC2 2 security group only       | EC2 1 and 3   | TCP ingress restricted to `app_monitoring_sg` for Nagios checks |

Security requirements:

- **Public Ingress Rule:** Public HTTP/HTTPS ingress (ports 80 and 443) is permitted **exclusively on EC2 2**. Neither EC2 1 nor EC2 3 accepts public HTTP/HTTPS traffic.
- Never expose Jenkins publicly (TCP 8080 restricted to EC2 2 SG).
- Never expose Puppet Server publicly (TCP 8140 restricted to agent SGs).
- Never expose NRPE publicly (TCP 5666 restricted to EC2 2 SG).
- Restrict SSH access to operator public IP /32 only.
- Use security group references for internal traffic wherever possible.
- Keep Nagios administrative access restricted: Apache loopback strictly on `127.0.0.1:8080`, accessible only via encrypted SSH tunnel (`ssh -L 8080:127.0.0.1:8080`).
- Do not expose secrets in frontend code.
- Do not commit AWS credentials or private keys.
- Do not permit arbitrary shell execution through repository URL inputs.

Review the existing VPC and subnet configuration before provisioning.

All three instances configure `associate_public_ip_address = true` within Default VPC public subnets for direct outbound connectivity, while strict ingress boundaries protect all internal management services.

---

# 5. APPLICATION REQUIREMENTS

Preferred backend:

- Node.js.
- Express.
- TypeScript.
- Zod.

Preferred frontend:

- React.
- TypeScript.
- Vite.
- Tailwind CSS.
- Recharts.

Proposed API:

```http
GET /api/health
POST /api/analyses
GET /api/analyses/:id
GET /api/analyses/:id/results
```

Canonical API Request & Response Contracts:
- `GET /api/health`: Returns HTTP 200 `{ "status": "UP", "timestamp": "..." }`.
- `POST /api/analyses`: Accepts `{ "repositoryUrl": "https://github.com/owner/repository" }`.
  - Validates repository URL and executes SSRF checks.
  - Generates application-level UUID v4 `analysisId`.
  - Returns HTTP 202 Accepted `{ "analysisId": "550e8400-e29b-41d4-a716-446655440000", "status": "QUEUED", "createdAt": "..." }`.
- `GET /api/analyses/:id`: Returns HTTP 200 with strictly application-level attributes:
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
- `GET /api/analyses/:id/results`: Returns HTTP 200 `{ "analysisId": "550e8400-e29b-41d4-a716-446655440000", "status": "COMPLETED", "metrics": { ... }, "summaryMarkdown": "...", "charts": { ... } }`.
- Legacy endpoints (`POST /api/analyze`, `GET /api/status/:buildId`, `GET /api/reports/:buildId`) are retired and superseded.
- **Identifier Abstraction Policy:** The public API exposes strictly application-generated UUIDs (`analysisId`). Internal Jenkins queue item IDs and build numbers are resolved and mapped internally by the Express backend (`analysisId` $\rightarrow$ `queueId` $\rightarrow$ `buildNumber`) and are never leaked to React clients.

Strict Security Specification for Untrusted Repository Input & Execution Sandboxing:
- **Strict GitHub Hostname Allowlisting:** The backend validates that submitted repository URLs target `github.com` exclusively. All other Git forges, arbitrary IP addresses, or local domain names are strictly rejected.
- **Canonical URL Parsing:** Validate input using standard Node.js `URL` parsing (`new URL(input)`).
- **Reject Dangerous URL Components:** Embedded credentials (`https://user:pass@...`), non-standard ports (anything other than 443), query parameters, fragments, and non-HTTPS protocols (`http://`, `ssh://`, `git://`, `file://`) are strictly rejected.
- **SSRF Protection:** Validate that host resolution does not target loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`), AWS Instance Metadata Service (`169.254.169.254`), or RFC 1918 private subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`). Protect against redirect-based SSRF bypass.
- **Zero Direct Shell Command Interpolation:** Never interpolate user-controlled repository URLs into shell execution strings. All parameters passed to Jenkins or tools must be structured.
- **Analyzer Container Isolation & Execution Sandboxing:**
  - Git hooks must **never execute**; Git commands enforce `-c core.hooksPath=/dev/null` on clone, fetch, and checkout.
  - Repository scripts, makefiles, and binaries must **never be executed** under any circumstances.
  - Submodules must not be recursively initialized (`--no-recurse-submodules`).
  - Analysis is restricted strictly to Git metadata inspection (`git log`, `git shortlog`, `git rev-parse`) and static line counting (`cloc`).
  - Bounded resource allocation: Container memory limit `1g` (`--memory=1g`), CPU limit `1.5` (`--cpus=1.5`), process limit `100` (`--pids-limit=100`), and repository disk allocation capped at 2 GB.
  - Bounded execution timeouts: Git clone operations timeout at 5 minutes; analysis container execution times out at 10 minutes.
  - Non-root execution: Container executes strictly as an unprivileged user (`--user $(id -u):$(id -g)`).
  - Workspace hygiene: Cloned repository files and temporary data are completely wiped from disk immediately after report generation.
- **Jenkins & Docker Security Rules:**
  - Jenkins TCP 8080 is accessible strictly from EC2 2's security group (`app_monitoring_sg`).
  - Backend execution user: Dedicated unprivileged system user `gitrepo` and group `gitrepo`.
  - Backend environment directory `/etc/git-repo-analyzer` owned by `root:gitrepo` with permissions `0750` (`rwxr-x---`).
  - Backend environment file `/etc/git-repo-analyzer/backend.env` owned by `root:gitrepo` with permissions `0640` (`rw-r-----` - root read/write, `gitrepo` group read-only, others no access).
  - Jenkins credentials must not be passed into the ephemeral analyzer container.
  - The host Docker socket (`/var/run/docker.sock`) is **never mounted** inside the analyzer container.
  - Docker group membership on EC2 3 is treated as root-equivalent access and strictly restricted.

Backend requirements:

- Validate public GitHub repository URLs using strict Zod schemas and standard URL parsing.
- Enforce SSRF protection and prevent arbitrary command execution.
- Abstract Jenkins integration behind an `IJenkinsClient` interface with a `MockJenkinsClient` for development and testing.
- Store Jenkins credentials in environment variables (`/etc/git-repo-analyzer/backend.env`).
- Trigger parameterized Jenkins jobs over the private network.
- Track queue IDs and resolve build numbers asynchronously.
- Poll Jenkins status and ingest archived artifacts upon completion.
- Maintain job status across backend restarts.

Frontend requirements:

Display:

- Total commits.
- Commits in the last 7 and 30 days.
- Commits per author.
- Lines added and removed.
- Most modified files.
- Stale branches.
- Daily activity charts.
- AI-generated insights.

Preserve the existing analyzer output format and Jenkins integration contract wherever possible.

Do not replace working functionality unnecessarily.

## Production deployment

- Build the React application for production.
- Serve static files through NGINX.
- Reverse proxy `/api/` to the backend.
- Never use the Vite development server in production.

---

# 6. ANSIBLE CONFIGURATION MANAGEMENT

Ansible is already installed and partially implemented.

Existing structure:

```text
ansible/
├── ansible.cfg
├── inventory/
│   └── hosts.ini
├── playbooks/
│   ├── site.yml
│   ├── test-common.yml
│   ├── test-docker.yml
│   └── test-nginx.yml
└── roles/
    ├── common/
    ├── docker/
    └── nginx/
```

The existing common, Docker, and NGINX roles have been tested.

Preserve them.

Extend the inventory:

```ini
[puppet_server]
puppet-server

[application]
app-server

[cicd]
cicd-server

[puppet_agents:children]
application
cicd
```

Do not invent IP addresses.

Configure actual addresses only after Terraform provisioning.

## Required roles

```text
roles/
├── common/
├── docker/
├── nginx/
├── puppet_server/
├── puppet_agent/
├── nagios/
└── nrpe/
```

### puppet_server

Target: EC2 1 only.

Responsibilities:

- Install Puppet Server.
- Configure hostname.
- Configure Puppet CA.
- Enable and start Puppet Server.
- Configure appropriate JVM settings.
- Prepare for certificate requests.

### puppet_agent

Target: EC2 2 and EC2 3.

Responsibilities:

- Install Puppet Agent.
- Configure Puppet Server address.
- Configure certificate identity.
- Enable and start Puppet Agent.

### nagios

Target: EC2 2 only.

Responsibilities:

- Install Nagios Core.
- Install monitoring plugins.
- Configure hosts and services.
- Configure application-server checks.
- Configure remote CI/CD checks through NRPE.
- Configure authentication.
- Enable and start Nagios.

### nrpe

Target: EC2 3 only.

Responsibilities:

- Install NRPE.
- Install monitoring plugins.
- Configure allowed hosts.
- Configure monitoring commands.
- Enable and start NRPE.

### Existing roles

- common: all three instances.
- docker: EC2 3.
- nginx: EC2 2.

Do not recreate functioning roles without a demonstrated reason.

---

# 7. ANSIBLE AND PUPPET OWNERSHIP

Ansible and Puppet must have clearly separated responsibilities governed by an explicit resource ownership matrix:

| Resource / Subsystem | Bootstrap Owner (Ansible) | Desired-State Owner (Puppet) | Handover & Operational Policy |
| :--- | :--- | :--- | :--- |
| **Base OS Packages & Tools** | Installs initial packages | Maintains package baseline | Ansible bootstraps once; Puppet manages ongoing packages. |
| **Swapfile Configuration** | Creates & activates swapfile | - | Ansible configures `/swapfile` (1 GB EC2 2, 2 GB EC2 3). |
| **Private DNS (`/etc/hosts`)** | Injects initial private IPs | Enforces `/etc/hosts` drift | Ansible injects before Puppet; Puppet enforces consistency. |
| **Docker Engine & Plugins** | Installs Docker CE on EC2 3 | - | Ansible configures Docker; adds `ubuntu` to `docker` group. |
| **Puppet Server & CA** | Installs & tunes JVM heap | - | Ansible installs packages, tunes JVM, starts `puppetserver`. |
| **Puppet Agent & Enrollment**| Installs agent & CSR submit | - | Ansible oversees controlled CSR signing; hands over to agent. |
| **NGINX Virtual Host & Config**| Installs baseline package | **Exclusively Owns** | Ansible installs package; Puppet manages virtual hosts and proxies. |
| **Node.js 20 LTS Runtime** | - | **Exclusively Owns** | Puppet deploys and manages Node.js runtime on EC2 2. |
| **Backend Systemd Service** | - | **Exclusively Owns** | Puppet deploys `git-repo-analyzer-backend.service` and env files. |
| **Nagios Core & Plugins** | - | **Exclusively Owns** | Puppet compiles, configures, and manages Nagios on EC2 2. |
| **NRPE Daemon & Checks** | - | **Exclusively Owns** | Puppet configures `nrpe.cfg` and check scripts on EC2 1 & EC2 3. |

Handover Policy:
- Ansible bootstraps Puppet and the base OS.
- Puppet manages ongoing desired configuration and drift remediation.
- Do not let both tools continuously overwrite the same files or services.
- Once a node is enrolled in Puppet, Ansible will never execute tasks that manage or overwrite NGINX virtual hosts, application systemd units, environment files, or Nagios/NRPE configurations.

---

# 8. PUPPET CONFIGURATION

Puppet Server must run exclusively on EC2 1.

Puppet Agent must run on EC2 2 and EC2 3.

Suggested structure:

```text
puppet/
├── manifests/
│   └── site.pp
└── modules/
    ├── common/
    ├── application/
    ├── cicd/
    ├── nginx/
    ├── docker/
    ├── jenkins/
    ├── nagios/
    └── nrpe/
```

Adapt this structure to the existing repository if necessary.

## Application node

Puppet should enforce:

- Common packages.
- Puppet Agent.
- NGINX.
- Nagios Core.
- Required monitoring configuration.

## CI/CD node

Puppet should enforce:

- Common packages.
- Puppet Agent.
- Docker.
- Jenkins.
- NRPE.
- Required monitoring configuration.

Use appropriate Puppet resources:

- package
- service
- file
- class
- node
- notify
- require

Use exec only when necessary.

Ensure manifests are idempotent.

## Certificate security

Do not automatically sign all certificate requests.

Use controlled certificate approval.

Use the Puppet Server's stable private hostname.

## Completion criteria

Puppet is not considered complete merely because packages are installed.

Both agents must:

1. Request certificates.
2. Receive approved certificates.
3. Successfully connect to Puppet Server.
4. Retrieve catalogs.
5. Apply catalogs successfully.

---

# 9. PUPPET SERVER RESOURCE MANAGEMENT

Puppet Server uses the JVM.

Because it has a dedicated EC2 instance, its memory allocation can be managed independently.

However:

- Check current official Puppet requirements.
- Evaluate JVM heap settings.
- Avoid unnecessary memory allocation.
- Consider the number of agents.
- Monitor actual memory consumption.
- Select the instance size based on workload.

Do not assume that a dedicated instance automatically eliminates every resource limitation.

---

# 10. NAGIOS AND NRPE

Nagios Core runs exclusively on EC2 2.

NRPE runs on EC2 1 and EC2 3.

## Application monitoring

Nagios Core on EC2 2 will monitor itself locally through monitoring plugins:

- Host availability.
- CPU load.
- Memory.
- Disk.
- NGINX process.
- Backend health endpoint.
- Frontend HTTP response.
- Nagios service.

## Remote infrastructure monitoring (NRPE)

Through NRPE over TCP 5666, Nagios Core on EC2 2 will monitor:

- **EC2 1 (Puppet Server):**
  - Host availability.
  - CPU load.
  - Memory.
  - Disk space.
  - `puppetserver` service status.
  - Port 8140 responsiveness.
- **EC2 3 (CI/CD Server):**
  - Host availability.
  - CPU load.
  - Memory.
  - Disk space.
  - Jenkins service status.
  - Docker daemon status.
  - NRPE daemon status.

## NRPE communication flow

```text
                           ┌──────────────────────────────┐
                           │    Application & Nagios      │
                           │           (EC2 2)            │
                           └──────────────┬───────────────┘
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  │ check_nrpe (TCP 5666)                         │ check_nrpe (TCP 5666)
                  ▼                                               ▼
   ┌──────────────────────────────┐                ┌──────────────────────────────┐
   │        Puppet Server         │                │     CI/CD & Analysis         │
   │           (EC2 1)            │                │           (EC2 3)            │
   │                              │                │                              │
   │ • Host ping & SSH            │                │ • Host ping & SSH            │
   │ • NRPE: CPU load, RAM, disk  │                │ • NRPE: CPU load, RAM, disk  │
   │ • NRPE: Puppetserver service │                │ • NRPE: Docker & Jenkins     │
   └──────────────────────────────┘                └──────────────────────────────┘
```

Only EC2 2 is permitted to connect to NRPE on EC2 1 and EC2 3.

## Nagios Web Architecture & Administrative Access

- **Web Server:** Nagios Core uses an Apache (`apache2`) virtual host / CGI module.
- **Port Binding:** Apache will bind strictly to loopback: `127.0.0.1:8080`.
- **Authentication:** Enforces HTTP Basic Authentication via `.htpasswd` (e.g. for `nagiosadmin`).
- **Reverse Proxy Separation:** NGINX runs on `0.0.0.0:80` and `443` for public application traffic. NGINX will **not** expose or proxy `/nagios`.
- **Encrypted SSH Tunneling:** Administrators access the dashboard via an encrypted SSH tunnel:
  ```bash
  ssh -i ~/.ssh/git-repo-analyzer.pem -L 8080:127.0.0.1:8080 ubuntu@<app-server-public-ip>
  ```
- **Browser Endpoint:** `http://localhost:8080/nagios`
- **Zero Public Access:** The Nagios interface is completely inaccessible from the public internet.

## Implementation Status Distinction

Important: Nagios and NRPE are approved designs scheduled for subsequent deployment, not currently running services.

| Component | Current Status |
|---|---|
| Terraform SG rules for NRPE (TCP 5666) | Implemented and validated |
| Nagios Core | Planned; not installed |
| NRPE daemon and plugins | Planned; not installed |
| Apache loopback configuration (`127.0.0.1:8080`) | Planned; not installed |
| HTTP Basic Authentication | Planned; not configured |
| SSH tunnel access | Design documented; not tested |

## Accepted limitation

Nagios Core runs on EC2 2.

If EC2 2 fails, its Nagios dashboard also becomes unavailable.

This limitation is accepted for the demonstration and should be documented.

Do not introduce another monitoring server to solve it.

---

# 11. INFRASTRUCTURE COST GOVERNANCE & PROVISIONING APPROVAL

1. No AWS infrastructure resource may be provisioned until its estimated cost, Free Tier eligibility, and potential additional charges have been reviewed and explicitly approved by the project owner.
2. Before provisioning, evaluate:

   - EC2 instance type eligibility and expected monthly instance-hours.
   - EBS volume type, capacity, and monthly storage charges.
   - Public IPv4 address charges.
   - Data transfer costs.
   - Other applicable AWS service charges.
3. Never assume an AWS resource is Free Tier eligible solely because of its instance family, size, or service category. Verify eligibility against the project's AWS account creation date, applicable Free Tier offer, and region (`ap-south-1`).
4. Provide a cost comparison and technical justification for alternative resource configurations before requesting approval.
5. Do not execute `terraform apply`, create AWS resources, or incur infrastructure charges without explicit approval.
6. Cost optimization must not silently compromise the approved three-EC2 architecture, security requirements, or minimum workload requirements. Any architectural changes require separate approval.
7. Treat all instance sizes, storage capacities, and infrastructure cost estimates as provisional until explicitly approved.

---

# 12. TERRAFORM INFRASTRUCTURE

Terraform already exists.

Current environment:

- Terraform 1.16.6.
- AWS Provider 6.70.0.
- AWS region: ap-south-1.
- Ubuntu 24.04 LTS.
- Existing S3 remote state backend.

Existing backend:

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

Preserve this backend.

Do not recreate it unnecessarily.

## Required resources

Provision three EC2 instances:

1. Puppet Server.
2. Application Server.
3. CI/CD Server.

Implementation Status: Complete and validated in commit `3dc78707a0329774152137fac6a225970793ef3d` on branch `feat/terraform-infrastructure`. Live deployment operates strictly on demand; `terraform apply` has **NOT** been run.

## Instance sizing & Lifecycle Strategy

Provisional sizing candidates (ADR 005 & ADR 010):
- Puppet Server: `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS).
- Application + Monitoring: `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS).
- CI/CD + Analysis: `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS).

Fleet Storage Total: Exactly 50 GB gp3 across all 3 nodes (15 GB + 15 GB + 20 GB).

On-Demand Ephemeral Lifecycle (ADR 011):
- Provision on-demand via `terraform apply`.
- Conduct demonstration or assessment.
- Completely tear down via `terraform destroy` when done.
- Instances do NOT run continuously 24/7. Fleet running rate is ~$0.0773/hour across compute, 50 GB gp3 storage, and 3 public IPv4 addresses (~$0.31 per 4-hour demonstration session).

## Networking and Security Groups

- **Public IPv4 Allocation:** All three instances explicitly configure `associate_public_ip_address = true` within the Default VPC public subnets, routing to the active Internet Gateway without an expensive NAT Gateway.
- **Inbound Security Boundaries:** Public IPv4 allocation does not grant unrestricted public inbound access; security groups strictly enforce least-privilege boundaries:

| Destination | Port | Allowed Source | Security Rationale |
|---|---:|---|---|
| EC2 2 — Application | 80, 443 | Public internet (`0.0.0.0/0`) | Public web app delivery (React UI / NGINX) |
| All three EC2 instances | 22 | Operator CIDR (`var.allowed_ssh_cidr`) | Administrative SSH access |
| EC2 1 — Puppet | 8140 | EC2 2 and EC2 3 security groups | Internal Puppet agent-to-master communication |
| EC2 3 — Jenkins | 8080 | EC2 2 security group | Internal backend API to Jenkins pipeline |
| EC2 1 — Puppet | 5666 | EC2 2 security group | Internal Nagios NRPE monitoring checks |
| EC2 3 — CI/CD | 5666 | EC2 2 security group | Internal Nagios NRPE monitoring checks |

- **Outbound Egress:** Enabled to `0.0.0.0/0` across all instances for apt, Docker Hub, GitHub, and Groq API calls.

## Persistent Remote State Backend

The S3 state bucket (`git-repo-analyzer-terraform-state-2026`) is permanent, independent infrastructure and must **never** be destroyed as part of the ephemeral EC2 fleet lifecycle.

## Outputs

Expose appropriate outputs:

- Puppet Server public/private IP, DNS, and ID.
- Application public/private IP, DNS, and ID.
- CI/CD public/private IP, DNS, and ID.
- Dynamically formatted Ansible inventory template (`ansible_inventory_template`).

Use outputs to configure Ansible inventory. Never invent IP addresses.

## Sensitive information

Never commit:

- `.pem` files.
- AWS credentials.
- `terraform.tfvars`.
- Terraform state files.
- Terraform plan files.
- Jenkins credentials.

Review `.gitignore`.

---

# 13. IMPLEMENTATION WORKFLOW

Implementation must be incremental and strictly adhere to the authoritative 9-phase roadmap defined in IMPLEMENTATION_PLAN.md:

Do not attempt to implement the entire project in one operation.

## Phase 1 — Repository Inspection & Alignment (Completed)
- Inspect existing codebase, verify live AWS state, and establish unified project governance.
- Verified: AWS caller identity, remote S3 state bucket active and empty, zero untagged resources.

## Phase 2 — Analyzer Script Fixes & Local Container Validation (Completed)
- Repaired `analyze2.sh`: restored `show_menu`, `show_commit_summary`, and `ZERO_COMMITS` initialization.
- Validated container execution in Docker locally for active and zero-commit repositories with exit code 0.

## Phase 3 — Terraform Multi-Instance Infrastructure & Networking (Completed)
- Defined three dedicated EC2 instances and directional security groups under the on-demand lifecycle model (ADR 011).
- Outbound internet access via Public IPv4; ingress strictly locked (ports 8140, 8080, 5666 restricted to peer security groups; SSH port 22 to operator CIDR; public 80/443 on Application Server only).
- Verified and validated with `terraform fmt -check`, `terraform validate`, and `git diff --check`. Committed in `3dc78707a0329774152137fac6a225970793ef3d` on branch `feat/terraform-infrastructure`.
- `terraform apply` has **NOT** been executed; zero live AWS resources have been provisioned or mutated. Live provisioning operates strictly on demand under ADR 010.

## Phase 4 — Ansible Bootstrap & Puppet Master/Agent Setup (Next Phase)
- Configure canonical inventory groups in `ansible/inventory/hosts.ini`: `[puppet_server]`, `[application]`, `[cicd]`, `[puppet_agents:children]`.
- Establish deterministic SSH host-key verification via EC2 serial console output and git-ignored `ansible/known_hosts`.
- Apply `roles/common` across all nodes (inject `/etc/hosts` private DNS mappings and configure swap).
- Author `roles/puppet_server`: install Puppet Server 8, tune JVM heap to `-Xms1g -Xmx1g`, start service.
- Author `roles/puppet_agent`: install `puppet-agent` on Instances 2 and 3, configure server address, submit CSRs.
- Controlled certificate signing: inspect CSRs with `puppetserver ca list` and sign explicitly per certname (`puppetserver ca sign --certname <agent-name>`). Bulk signing (`--all`) and autosigning are prohibited.
- Extend `roles/docker`: install Docker CE on Instance 3 and add `ubuntu` to `docker` group (adding `jenkins` user is deferred to Phase 7).

## Phase 5A — Puppet Foundations & Monitoring Prerequisites
- Author Puppet manifests/modules for foundational system configuration:
  - Base packages and directory structures on all nodes.
  - Deploy NRPE daemon on EC2 1 and EC2 3 (restrict `allowed_hosts` strictly to EC2 2 private IP).
  - Deploy Nagios Core build prerequisites and Apache loopback virtual host (`127.0.0.1:8080`) on EC2 2.
- Verify catalog compilation and execution on all nodes.
- Enforce Ansible-to-Puppet ownership handover boundaries.

## Phase 6 — Application Development (Backend API & Frontend UI with Mock Jenkins)
- Backend: Express API with canonical `/api/analyses` endpoints, Zod URL parsing & SSRF guards, and `IJenkinsClient` abstraction with `MockJenkinsClient`.
- Frontend: React/Vite SPA with submission form, polling hook with backoff, and report/chart visualization dashboard.
- Author automated tests verifying API contracts and mock pipeline progression.
- Finalize systemd service unit, NGINX routing, and environment variable contracts for Puppet Phase 5B.

## Phase 5B — Puppet-Managed Application Configuration
- Author Puppet manifests to deploy finalized application contracts on EC2 2:
  - Deploy Node.js 20 LTS runtime.
  - Deploy backend systemd service unit (`git-repo-analyzer-backend.service`) and environment file (`/etc/git-repo-analyzer/backend.env`).
  - Deploy NGINX production virtual host serving React static assets and reverse-proxying `/api/` to Express.
- Verify desired-state enforcement and configuration drift correction.

## Phase 7 — Jenkins Pipeline Configuration & Real Backend Integration
- Install Jenkins Controller on Instance 3; tune JVM heap to `-Xms384m -Xmx512m`.
- Add `jenkins` system user to the `docker` group.
- Store `GROQ_API_KEY` in Jenkins Credentials Store as secret text.
- Create parameterized pipeline job loaded with `Jenkinsfile`.
- Switch Express backend from Mock to Live Jenkins client via private network API.
- Verify end-to-end flow: Frontend submission → Backend → Jenkins → Docker Analyzer → Artifacts archived → Backend retrieval → Frontend display.

## Phase 8 — Monitoring Configuration & End-to-End System Verification
- Finalize Nagios Core active service checks on Instance 2 for Instance 1 (Puppet), Instance 2 (Local App), and Instance 3 (Remote NRPE).
- Verify Nagios administrative dashboard access over encrypted SSH tunnel (`localhost:8080/nagios`).
- Validate configuration drift correction: modify NGINX manually, verify Puppet run reverts changes.
- Perform end-to-end validation on public repositories (standard, high-churn, and zero-commit).
- Execute `terraform destroy` to verify clean ephemeral teardown.

---

# 14. STRICT DEVELOPMENT RULES

1. Never discard existing working code without justification.
2. Never rewrite the analyzer unnecessarily.
3. Never introduce Kubernetes without approval.
4. Never introduce Redis or an additional database without justification and approval.
5. Never introduce a fourth EC2 instance without approval.
6. Never install Puppet Server on EC2 2 or EC2 3.
7. Never install Nagios Core outside EC2 2.
8. Never install NRPE outside EC2 1 or EC2 3 (never on EC2 2).
9. Never expose Jenkins publicly.
10. Never expose Puppet publicly.
11. Never expose NRPE publicly.
12. Never expose secrets in source code.
13. Never use the Vite development server in production.
14. Never hardcode temporary IP addresses.
15. Never allow arbitrary shell execution through user input.
16. Never let Ansible and Puppet compete for the same resource.
17. **Strictly Separate Implementation vs Provisioning Approvals**:
    - **Approval Boundary A (Implementation Approval):** Permission to author or edit project code, Ansible roles, Puppet manifests, tests, and documentation.
    - **Approval Boundary B (AWS Provisioning Approval):** Permission to execute `terraform apply` and create billable AWS infrastructure.
    - **Rule:** Approval for Boundary A **never implies** approval for Boundary B. Authoring Phase 4 code does not authorize live AWS infrastructure creation or live Ansible execution against EC2 instances.
18. Never execute Terraform apply without explicit written approval (Boundary B).
19. Never execute Terraform destroy without explicit approval.
20. Never overwrite or reconfigure the existing S3 remote state backend (`git-repo-analyzer-terraform-state-2026`).
21. Store private keys outside the repository: Target canonical location is `~/.ssh/git-repo-analyzer.pem` with restrictive permissions (`0400`). `.gitignore` is not an equivalent security substitute for keeping private keys outside project workspaces.
22. Always inspect before modifying.
23. Always test after implementation.
24. Always explain significant architectural decisions.
25. Always report files changed and commands executed.
26. Work incrementally and wait for approval between major stages.

---

# 15. GIT AND CHANGE MANAGEMENT

Before every major implementation phase:

Inspect:

```bash
git status
```

Create a checkpoint after reviewing the changes:

```bash
git add <reviewed-files>
git commit -m "checkpoint: <phase-name>"
```

Do not blindly stage all files.

Exclude:

- Private keys.
- Credentials.
- Terraform state.
- Terraform plans.
- Local environment files.
- Sensitive configuration.

Never rewrite Git history or force-push without explicit approval.

---

# 16. REPORTING REQUIREMENTS

At the end of every implementation stage, report:

1. What was implemented.
2. Files created.
3. Files modified.
4. Existing functionality preserved.
5. Commands executed.
6. Tests performed.
7. Test results.
8. Outstanding issues.
9. Security considerations.
10. Next recommended stage.

Do not claim something works without testing it.

Clearly distinguish:

- Implemented.
- Configured.
- Locally tested.
- Deployed.
- Verified in AWS.

---

# FINAL INSTRUCTION

This file is the permanent source of truth for the project's approved architecture and constraints.

If a later request appears to conflict with this architecture, identify the conflict before making changes.

Do not silently change architectural decisions.

Start with Stage 1: Repository Inspection Only.

Do not modify any files until the inspection report is reviewed and approved.
