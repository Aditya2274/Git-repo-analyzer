# 📊 Git Repository Analyzer  
A powerful, single-file, menu-driven tool to analyze any Git repository — with automatic reports, charts, commit statistics, file modification history, stale branch detection, and more.

`analyze4.sh` works on **any local Git repository** and requires **zero configuration**.  
Just drop the script into a repo and run it.

---

## 🚀 Features

### ✅ **Interactive Menu**
Choose what you want to run:

1)Run Full Analysis

2)Generate Charts Only

3)Show Commit Summary

4)Exit

### ✅ **Full Analysis Includes**
- Total commits  
- Commits in last 7 days  
- Commits in last 30 days  
- Commits per author  
- Lines added / removed  
- Most modified files  
- Stale branches (no activity for 30 days)  
- Automatically generated Markdown report  
- Embedded charts (PNG)

### ✅ **Charts (Matplotlib)**
The tool generates beautiful charts:

- **Commits per Author bar chart**  
- **Daily Commit Activity line chart**

Saved in:
reports/charts/


### ✅ **Markdown Report**
All analysis results go into:
reports/summary.md


Charts are embedded directly inside the report.

### ✅ **Safe for NEW repos (0 commits)**
The script gracefully handles:

- Repositories with *zero commits*  
- Missing authors  
- No branches  
- No file changes  

No more fatal errors like:
fatal: ambiguous argument 'HEAD'

---

## 📥 Installation

Clone this repo:

```bash
git clone https://github.com/Aditya2274/git-repo-analyzer.git
cd git-repo-analyzer

Make the script executable:
chmod +x analyze4.sh

🧪 Usage

1)Copy analyze4.sh into any Git repository:

cp analyze4.sh /path/to/your/repo
cd /path/to/your/repo

2)Run the analyzer:
bash analyze4.sh

3)Choose an option from the menu.

📄 Output Structure

reports/
│
├── summary.md          # Main Markdown Report
└── charts/
    ├── commits_per_author.png
    └── daily_commit_activity.png

🛠 Requirements

Git

Python 3

Matplotlib
If missing, the script installs it automatically using:
   pip3 install --user matplotlib

or on Ubuntu:
   sudo apt install python3-matplotlib
