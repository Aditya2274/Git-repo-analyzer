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

Implement least-privilege security groups.

| Port | Service | Source                          | Destination   |
| ---- | ------- | ------------------------------- | ------------- |
| 22   | SSH     | My public IP                    | EC2 instances |
| 80   | HTTP    | Public internet                 | EC2 2         |
| 443  | HTTPS   | Public internet                 | EC2 2         |
| 8080 | Jenkins | EC2 2 security group            | EC2 3         |
| 8140 | Puppet  | EC2 2 and EC2 3 security groups | EC2 1         |
| 5666 | NRPE    | EC2 2 security group            | EC2 3         |

Security requirements:

- Never expose Jenkins publicly.
- Never expose Puppet Server publicly.
- Never expose NRPE publicly.
- Restrict SSH access to my public IP.
- Use security group references for internal traffic wherever possible.
- Keep Nagios administrative access restricted.
- Prefer SSH tunneling or another restricted access mechanism for the Nagios dashboard.
- Do not expose secrets in frontend code.
- Do not commit AWS credentials or private keys.
- Do not permit arbitrary shell execution through repository URL inputs.

Review the existing VPC and subnet configuration before provisioning.

Do not assume that every instance requires a public IP.

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

Example request:

```json
{
  "repositoryUrl": "https://github.com/owner/repository"
}
```

Backend requirements:

- Validate public GitHub repository URLs.
- Prevent SSRF.
- Prevent arbitrary command execution.
- Store Jenkins credentials in environment variables.
- Trigger parameterized Jenkins jobs.
- Track queue IDs and build numbers.
- Poll asynchronously for completion.
- Retrieve artifacts securely.
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

Ansible and Puppet must have clearly separated responsibilities.

| Responsibility                   | Owner                   |
| -------------------------------- | ----------------------- |
| Initial server configuration     | Ansible                 |
| Initial package repository setup | Ansible                 |
| Puppet Server installation       | Ansible                 |
| Puppet Agent installation        | Ansible                 |
| Initial certificate enrollment   | Ansible-assisted/manual |
| Ongoing OS configuration         | Puppet                  |
| Ongoing service configuration    | Puppet                  |
| Application container lifecycle  | Docker Compose          |
| CI/CD execution                  | Jenkins                 |
| Monitoring                       | Nagios                  |

Ansible bootstraps Puppet.

Puppet manages ongoing desired configuration.

Do not let both tools continuously overwrite the same files or services.

Document resource ownership.

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

NRPE runs exclusively on EC2 3.

## Application monitoring

Nagios should monitor:

- Host availability.
- CPU load.
- Memory.
- Disk.
- NGINX.
- Backend health endpoint.
- Frontend HTTP response.
- Nagios service.

## CI/CD monitoring

Through NRPE, Nagios should monitor:

- Host availability.
- CPU load.
- Memory.
- Disk.
- Jenkins.
- Docker.
- NRPE.

## NRPE communication

```text
EC2 2
Nagios Core
    |
    | check_nrpe
    |
    | TCP 5666
    v
EC2 3
NRPE
    |
    | Monitoring Plugins
    |
    v
Local checks
    |
    v
Results returned to Nagios
```

Only EC2 2 should be able to connect to NRPE on EC2 3.

Install and configure compatible Nagios plugins.

Do not assume a `check_cpu` plugin exists by default. Verify the actual installed plugins and commands.

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

Use reusable modules where appropriate.

Review the existing Terraform module before modifying it.

## Instance sizing & Lifecycle Strategy

Provisional sizing candidates (ADR 005 & ADR 010):
- Puppet Server: `t3.small` (2 vCPU, 2 GB RAM, 15 GB gp3 EBS).
- Application + Monitoring: `t3.micro` (2 vCPU, 1 GB RAM, 15 GB gp3 EBS).
- CI/CD + Analysis: `t3.small` (2 vCPU, 2 GB RAM, 20 GB gp3 EBS).

On-Demand Ephemeral Lifecycle (ADR 011):
- Provision on-demand via `terraform apply`.
- Conduct demonstration or assessment.
- Completely tear down via `terraform destroy` when done.
- Instances do not run continuously 24/7. Fleet running rate is ~$0.0773/hour across compute, 50 GB gp3 storage, and 3 public IPv4 addresses (~$0.31 per 4-hour demonstration session).

## Storage

Fleet Storage Total: Exactly 50 GB gp3 across all 3 nodes (15 GB + 15 GB + 20 GB).

Consider Docker images, Jenkins workspaces, artifacts, logs, and application files.

## Outputs

Expose appropriate outputs:

- Puppet Server private address.
- Application public address.
- Application private address.
- CI/CD private address.
- CI/CD public address, if required.

Use outputs to configure Ansible inventory.

Never invent IP addresses.

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

Implementation must be incremental and strictly adhere to the 8-phase roadmap defined in IMPLEMENTATION_PLAN.md.

Do not attempt to implement the entire project in one operation.

## Phase 1 — Repository Inspection & Alignment (Completed)
- Inspect existing codebase, verify live AWS state, and establish unified project governance.
- Verified: AWS caller identity, remote S3 state bucket active and empty, zero untagged resources.

## Phase 2 — Analyzer Script Fixes & Local Container Validation (Completed)
- Repaired `analyze2.sh`: restored `show_menu`, `show_commit_summary`, and `ZERO_COMMITS` initialization.
- Validated container execution in Docker locally for active and zero-commit repositories with exit code 0.

## Phase 3 — Terraform Multi-Instance Infrastructure & Networking (Pending Written Approval)
- Author reproducible Terraform definitions for the three dedicated EC2 instances and directional security groups under the on-demand lifecycle model (ADR 011).
- Outbound internet access via Public IPv4; ingress strictly locked (ports 8140, 8080, 5666 restricted to peer security groups; SSH port 22 to operator CIDR; public 80/443 on Application Server only).
- Strictly blocked under ADR 010: Never execute `terraform apply` without explicit written approval.

## Phase 4 — Ansible Bootstrap & Puppet Master/Agent Setup
- Configure inventory groups in `ansible/inventory/hosts.ini`: `[puppet_server]`, `[application]`, `[cicd]`, `[puppet_agents:children]`.
- Apply `roles/common` across all nodes.
- Author `roles/puppet_server`: install Puppet Server 8, tune JVM heap to `-Xms1g -Xmx1g`, start service.
- Author `roles/puppet_agent`: install `puppet-agent` on Instances 2 and 3, configure server address, initiate CSRs.
- Controlled certificate signing: inspect CSRs with `puppetserver ca list` and sign explicitly per certname (`puppetserver ca sign --certname <agent-name>`). Bulk signing (`--all`) and autosigning are prohibited.
- Extend `roles/docker`: install Docker CE on Instance 3 and add `jenkins` and `ubuntu` to `docker` group.

## Phase 5 — Puppet Continuous Configuration Management
- Author Puppet manifests/modules for ongoing desired state enforcement:
  - Application Server: manage NGINX virtual host, Node.js 20 LTS runtime, Express systemd unit, Nagios Core, and plugins.
  - CI/CD Server: manage NRPE daemon (`nrpe.cfg`), restrict `allowed_hosts` to Application Server private IP, deploy check scripts.
- Verify catalog compilation and execution on both agent nodes.

## Phase 6 — Application Development (Backend API & Frontend UI)
- Backend: Express API with `POST /api/analyze`, `GET /api/status/:buildId`, `GET /api/reports/:buildId`, and Jenkins API client.
- Frontend: React/Vite SPA with submission form, polling hook, and report/chart visualization dashboard.
- Serve production build via NGINX with `/api/` reverse proxy.

## Phase 7 — Jenkins Pipeline Configuration & Backend Integration
- Install Jenkins on Instance 3, configure admin credentials and API token.
- Store `GROQ_API_KEY` in Jenkins Credentials Store.
- Create pipeline job loaded with `Jenkinsfile`.
- Verify end-to-end flow: Frontend submission → Backend → Jenkins → Docker Analyzer → Artifacts archived → Backend retrieval → Frontend display.

## Phase 8 — Monitoring Configuration & End-to-End System Verification
- Configure Nagios Core service checks on Instance 2 for Instance 1 (Puppet), Instance 2 (Local App), and Instance 3 (Remote NRPE).
- Verify Nagios administrative dashboard access over encrypted SSH tunnel.
- Validate configuration drift correction: modify NGINX manually, verify Puppet run reverts changes.
- Perform end-to-end validation on public repositories.

---

# 14. STRICT DEVELOPMENT RULES

1. Never discard existing working code without justification.
2. Never rewrite the analyzer unnecessarily.
3. Never introduce Kubernetes without approval.
4. Never introduce Redis or an additional database without justification and approval.
5. Never introduce a fourth EC2 instance without approval.
6. Never install Puppet Server on EC2 2 or EC2 3.
7. Never install Nagios Core outside EC2 2.
8. Never install NRPE outside EC2 3.
9. Never expose Jenkins publicly.
10. Never expose Puppet publicly.
11. Never expose NRPE publicly.
12. Never expose secrets in source code.
13. Never use the Vite development server in production.
14. Never hardcode temporary IP addresses.
15. Never allow arbitrary shell execution through user input.
16. Never let Ansible and Puppet compete for the same resource.
17. Never execute Terraform apply without explicit approval.
18. Never execute Terraform destroy without explicit approval.
19. Never overwrite the existing S3 remote state backend.
20. Never delete existing project files without approval.
21. Always inspect before modifying.
22. Always test after implementation.
23. Always explain significant architectural decisions.
24. Always report files changed and commands executed.
25. Work incrementally and wait for approval between major stages.

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
