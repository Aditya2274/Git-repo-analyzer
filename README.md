# Git Repository Analyzer

A cross-platform, menu-driven CLI tool to analyze Git repositories and generate
detailed reports with charts and commit statistics.

The tool works natively on Linux/macOS, supports Windows users, and also provides
a fully Dockerized option for OS-independent execution.

---

## Features

### Interactive Menu
- Run Full Analysis
- Generate Charts Only
- Show Commit Summary
- Exit

### Full Analysis Includes
- Total commits
- Commits in the last 7 and 30 days
- Commits per author
- Lines added and removed
- Most modified files
- Stale branch detection (30+ days inactivity)
- Auto-generated Markdown report
- Embedded charts (PNG)

### Charts (Matplotlib)
- Commits per Author (bar chart)
- Daily Commit Activity (line chart)

Charts are stored in:
reports/charts/


### Markdown Report
All results are compiled into:


reports/summary.md


Charts are embedded directly in the report.

---

## Zero-Commit Repository Support

The analyzer safely handles:
- Empty repositories
- No commits
- Missing authors
- No file changes

This prevents common Git errors such as:fatal: ambiguous argument 'HEAD'


---

## Usage Options

### 1. Native (Linux / macOS)

```bash
chmod +x analyze2.sh
bash analyze2.sh
```
2. Windows

Use the Windows-compatible script with Git Bash or WSL:
```
bash analyzer-win.sh
```
3. Docker (Recommended for Cross-Platform Use)

No dependencies required except Docker.
```
docker pull adityaashok2274/git-repo-analyzer:1.0.0
```
```
docker run -it \
  --user $(id -u):$(id -g) \
  -v "$(pwd)":/repo \
  adityaashok2274/git-repo-analyzer:1.0.0
```

This runs the analyzer safely as a non-root user and avoids permission issues.

CI/CD Usage Example (Optional)

In real-world DevOps pipelines, this tool can be used as a reporting step:

docker run --rm -v "$PWD":/repo adityaashok2274/git-repo-analyzer:1.0.0


Generated reports can be stored as pipeline artifacts.

Requirements (Non-Docker)

Git

Python 3

Matplotlib

If Matplotlib is missing, the script installs it automatically.

License:
Open-source and free to use.
