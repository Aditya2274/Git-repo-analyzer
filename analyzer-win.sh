#!/usr/bin/env bash
set -u

###############################################################################
# Helper print functions
###############################################################################
err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

###############################################################################
# Ensure Git repo
###############################################################################
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "Not inside a git repository."
  exit 1
fi

###############################################################################
# Detect Python (python3 or python), with optional override
###############################################################################
detect_python() {
  # 1) If user already set PYTHON, trust it (if it works)
  if [ -n "${PYTHON:-}" ]; then
    if "$PYTHON" -c "import sys" >/dev/null 2>&1; then
      return
    else
      err "PYTHON='$PYTHON' is not a working Python interpreter."
      exit 1
    fi
  fi

  # 2) Try python3 first (Linux/macOS, some Windows)
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import sys" >/dev/null 2>&1; then
      PYTHON=python3
      return
    fi
  fi

  # 3) Try python (often correct on Windows + Git Bash)
  if command -v python >/dev/null 2>&1; then
    if python -c "import sys" >/dev/null 2>&1; then
      PYTHON=python
      return
    fi
  fi

  err "Python 3 is required but not found. Install it or run with: PYTHON=/path/to/python3 ./analyze2.sh"
  exit 1
}

detect_python

###############################################################################
# Detect ZERO commits
###############################################################################
if git rev-parse HEAD >/dev/null 2>&1; then
  ZERO_COMMITS=false
else
  ZERO_COMMITS=true
fi

###############################################################################
# MENU
###############################################################################
show_menu() {
  echo
  echo "======================================="
  echo "      Git Repository Analyzer Menu"
  echo "======================================="
  echo "1) Run Full Analysis"
  echo "2) Generate Charts Only"
  echo "3) Show Commit Summary"
  echo "4) Exit"
  echo "---------------------------------------"
  read -rp "Enter your choice: " choice
}

###############################################################################
# Generate Charts Only
###############################################################################
generate_charts_only() {

  if [ "$ZERO_COMMITS" = true ]; then
    echo "No commits found — skipping charts."
    return
  fi

  echo "Generating charts only..."

"$PYTHON" - <<'PYTHON_GENERATOR'
import os, subprocess, sys
from collections import Counter
import datetime

def run(cmd_list):
    try:
        return subprocess.check_output(cmd_list, text=True).strip()
    except Exception:
        return ""

# Zero commit check
if run(["git", "rev-parse", "HEAD"]) == "":
    print("No commits — skipping charts.")
    sys.exit(0)

# Setup
CHART_DIR = os.path.join("reports", "charts")
os.makedirs(CHART_DIR, exist_ok=True)

# Try import matplotlib
try:
    import matplotlib.pyplot as plt
except ImportError:
    print("Installing matplotlib via pip...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "matplotlib"])
        import matplotlib.pyplot as plt
    except Exception as e:
        print("Failed to install matplotlib:", e)
        sys.exit(1)

# ----------------------------------------
# Chart 1: Commits Per Author
# ----------------------------------------
data = run(["git", "shortlog", "-s", "-n", "--all"])
if data:
    authors, commits = [], []
    for line in data.splitlines():
        parts = line.split()
        commits.append(int(parts[0]))
        authors.append(" ".join(parts[1:]))
    plt.figure(figsize=(8, 4))
    plt.bar(authors, commits)
    plt.xticks(rotation=30)
    plt.title("Commits per Author")
    plt.tight_layout()
    plt.savefig(os.path.join(CHART_DIR, "commits_per_author.png"))
    plt.close()

# ----------------------------------------
# Chart 2: Daily Commit Activity
# ----------------------------------------
dates_raw = run(["git", "log", "--date=short", "--pretty=format:%ad"])
if dates_raw:
    dates = dates_raw.splitlines()
    c = Counter(dates)
    days = sorted(c.keys())
    x = [datetime.datetime.strptime(d, "%Y-%m-%d") for d in days]
    y = [c[d] for d in days]

    plt.figure(figsize=(10, 4))
    plt.plot(x, y, marker="o")
    plt.xticks(rotation=30)
    plt.title("Daily Commit Activity")
    plt.tight_layout()
    plt.savefig(os.path.join(CHART_DIR, "daily_commit_activity.png"))
    plt.close()

print("Charts generated.")
PYTHON_GENERATOR
}

###############################################################################
# Commit summary (works even with ZERO commits)
###############################################################################
show_commit_summary() {

  echo
  echo "Commit Summary"
  echo "---------------------------------------"

  if [ "$ZERO_COMMITS" = true ]; then
    echo "No commits found."
    return
  fi

  echo "Total commits: $(git rev-list --count HEAD 2>/dev/null)"
  echo "Commits last 7 days: $(git rev-list --count --since='7 days ago' HEAD 2>/dev/null)"
  echo "Commits last 30 days: $(git rev-list --count --since='30 days ago' HEAD 2>/dev/null)"
  echo

  git shortlog -s -n --all 2>/dev/null
}

###############################################################################
# FULL Analysis
###############################################################################
run_full_analysis() {

REPORT_DIR="reports"
CHART_DIR="$REPORT_DIR/charts"
mkdir -p "$CHART_DIR"

# -------------------------- STATS --------------------------
if [ "$ZERO_COMMITS" = true ]; then
  total_commits=0
  commits_last7=0
  commits_last30=0
  commits_per_author_raw="No commits"
  insertions=0
  deletions=0
  most_modified="No file changes"
  stale_branches="No stale branches"
else
  total_commits=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  commits_last7=$(git rev-list --count --since='7 days ago' HEAD 2>/dev/null || echo 0)
  commits_last30=$(git rev-list --count --since='30 days ago' HEAD 2>/dev/null || echo 0)
  commits_per_author_raw=$(git shortlog -s -n --all 2>/dev/null)

  insertions=$(git log --pretty=tformat: --numstat 2>/dev/null |
      awk 'BEGIN{n=0} $1~/^[0-9]+$/ {n+=$1} END{print n}')

  deletions=$(git log --pretty=tformat: --numstat 2>/dev/null |
      awk 'BEGIN{n=0} $2~/^[0-9]+$/ {n+=$2} END{print n}')

  most_modified=$(git log --name-only --pretty=format: 2>/dev/null |
      grep -v '^$' | sort | uniq -c | sort -nr | head -10)

  now=$(date +%s)
  threshold=$((30*24*60*60))
  stale_branches=$(git for-each-ref --format='%(refname:short) %(committerdate:unix)' refs/heads/ 2>/dev/null |
      awk -v now="$now" -v th="$threshold" '{ if(now-$2>th) print "  "$1 }')
fi

# ----------------------- INITIAL REPORT ----------------------
REPORT_FILE="$REPORT_DIR/summary.md"

{
  echo "# Git Repository Analysis Report"
  echo "Generated on: $(date)"
  echo
  if [ "$ZERO_COMMITS" = true ]; then
    echo "**No commits found — charts will be skipped.**"
    echo
  fi
  echo "## Summary"
  echo "- Total Commits: $total_commits"
  echo "- Commits last 7 days: $commits_last7"
  echo "- Commits last 30 days: $commits_last30"
  echo
  echo "## Commits Per Author"
  echo "$commits_per_author_raw"
  echo
  echo "## Code Changes"
  echo "- Lines Added: $insertions"
  echo "- Lines Removed: $deletions"
  echo
  echo "## Most Modified Files"
  echo "$most_modified"
  echo
  echo "## Stale Branches"
  echo "$stale_branches"
  echo
} > "$REPORT_FILE"

# ------------------------- PYTHON (CHARTS) -------------------------
if [ "$ZERO_COMMITS" = false ]; then
"$PYTHON" - <<'PYTHON_GENERATOR'
import os, sys, subprocess
from collections import Counter
import datetime

def run(cmd_list):
    try:
        return subprocess.check_output(cmd_list, text=True).strip()
    except Exception:
        return ""

CHART_DIR = os.path.join("reports", "charts")
os.makedirs(CHART_DIR, exist_ok=True)

try:
    import matplotlib.pyplot as plt
except ImportError:
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "matplotlib"])
        import matplotlib.pyplot as plt
    except Exception as e:
        print("Failed to install matplotlib:", e)
        sys.exit(1)

# Author chart
raw = run(["git", "shortlog", "-s", "-n", "--all"])
if raw:
    authors, counts = [], []
    for line in raw.splitlines():
        p = line.split()
        counts.append(int(p[0]))
        authors.append(" ".join(p[1:]))
    plt.figure(figsize=(8, 4))
    plt.bar(authors, counts)
    plt.xticks(rotation=30)
    plt.title("Commits Per Author")
    plt.tight_layout()
    plt.savefig(os.path.join(CHART_DIR, "commits_per_author.png"))
    plt.close()

# Daily activity
raw = run(["git", "log", "--date=short", "--pretty=format:%ad"])
if raw:
    dates = raw.splitlines()
    c = Counter(dates)
    days = sorted(c.keys())
    x = [datetime.datetime.strptime(d, "%Y-%m-%d") for d in days]
    y = [c[d] for d in days]
    plt.figure(figsize=(10, 4))
    plt.plot(x, y, marker="o")
    plt.xticks(rotation=30)
    plt.title("Daily Commit Activity")
    plt.tight_layout()
    plt.savefig(os.path.join(CHART_DIR, "daily_commit_activity.png"))
    plt.close()
PYTHON_GENERATOR
fi

# ----------------------- FINAL REPORT -----------------------
{
  echo "# Git Repository Analysis Report"
  echo "Generated on: $(date)"
  echo
  echo "## Summary"
  echo "- Total Commits: $total_commits"
  echo "- Commits last 7 days: $commits_last7"
  echo "- Commits last 30 days: $commits_last30"
  echo
  echo "## Commits Per Author"
  echo "$commits_per_author_raw"
  echo
  echo "## Code Changes"
  echo "- Lines Added: $insertions"
  echo "- Lines Removed: $deletions"
  echo
  echo "## Most Modified Files"
  echo "$most_modified"
  echo
  echo "## Stale Branches"
  echo "$stale_branches"
  echo
  echo "## Charts"
  if [ "$ZERO_COMMITS" = false ]; then
    echo "### Commits Per Author"
    echo "![chart](charts/commits_per_author.png)"
    echo
    echo "### Daily Commit Activity"
    echo "![chart](charts/daily_commit_activity.png)"
  else
    echo "**Charts unavailable — repository has no commits.**"
  fi
} > "$REPORT_FILE"

echo
echo "Full analysis complete!"
echo "Report written to $REPORT_FILE"

} # end full analysis

###############################################################################
# MAIN MENU
###############################################################################
while true; do
  show_menu
  case $choice in
    1) run_full_analysis ;;
    2) generate_charts_only ;;
    3) show_commit_summary ;;
    4) echo "Goodbye!"; exit 0 ;;
    *) echo "Invalid choice. Enter 1–4." ;;
  esac
done
