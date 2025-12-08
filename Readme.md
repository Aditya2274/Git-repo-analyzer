# Git Repository Analyzer

A powerful, single-file, menu-driven tool to analyze any Git repository with automatic reports, charts, commit statistics, file modification history, stale branch detection, and more.

`analyze4.sh` works on any local Git repository and requires zero configuration.  
Simply place the script inside a repository and run it.

A Windows-compatible script, `analyzer_win.sh`, is also included for Windows users.

---

## Features

### Interactive Menu

Choose from the following options:

1. Run Full Analysis  
2. Generate Charts Only  
3. Show Commit Summary  
4. Exit  

---

## Full Analysis Includes

- Total commits  
- Commits in the last 7 days  
- Commits in the last 30 days  
- Commits per author  
- Lines added and removed  
- Most modified files  
- Stale branches (no activity for 30+ days)  
- Automatically generated Markdown report  
- Embedded charts (PNG format)

---

## Charts (Matplotlib)

The tool generates:

- **Commits per Author** (bar chart)  
- **Daily Commit Activity** (line chart)

Charts are stored in:

reports/charts/
---

## Markdown Report

All results are compiled into:

reports/summary.md
Charts are embedded directly inside the report.

---

## Zero-Commit Repository Support

The script safely handles:

- Empty repositories  
- Missing authors  
- No branches  
- No file changes  

This prevents Git errors such as:

fatal: ambiguous argument 'HEAD'
---

## Installation

Clone the project:

```bash
git clone https://github.com/Aditya2274/git-repo-analyzer.git
cd git-repo-analyzer

Make both scripts executable:

chmod +x analyze4.sh
chmod +x analyzer_win.sh

Usage:
Linux / macOS

1)Copy the script into a Git repository:
   cp analyze4.sh /path/to/your/repo
   cd /path/to/your/repo
2)Run the tool:
   bash analyze4.sh

Windows

For Windows users, use the dedicated script:

1)Copy analyzer_win.sh into your repository.
2)Run using Git Bash or WSL:
   bash analyzer_win.sh

Output Structure
reports/
│
├── summary.md
└── charts/
    ├── commits_per_author.png
    └── daily_commit_activity.png

Requirements:
->Git
->Python 3
->Matplotlib
->If Matplotlib is missing, the script installs it automatically using:
     pip3 install --user matplotlib
  Or on Ubuntu:
     sudo apt install python3-matplotlib

License
This project is open-source and free to use.

Contributions
Feel free to submit pull requests or open issues for improvements or bug fixes.

---

If you want, I can also:

✔ Add badges (build status, license, stars, forks, etc.)  
✔ Make a more stylish GitHub README with images and banners  
✔ Generate release notes or documentation  

Just tell me!
