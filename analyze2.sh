###############################################################################
# CHART HELPERS
###############################################################################
ensure_chart_dependencies() {
  if node -e 'require.resolve("chartjs-node-canvas")' >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to generate charts outside Docker, but it is not installed."
    return 1
  fi

  echo "Chart dependencies are missing; installing local Node packages..."
  npm install --no-save chartjs-node-canvas chart.js dotenv @langchain/groq @langchain/core >/dev/null 2>&1 || {
    echo "Unable to install chart rendering dependencies."
    return 1
  }
}

generate_charts() {
  if [ "$ZERO_COMMITS" = true ]; then
    echo "No commits found; skipping chart generation."
    return 0
  fi

  if ! ensure_chart_dependencies; then
    return 1
  fi

  node /tool/ai/chartGenerator.js
}

generate_charts_only() {
  generate_charts
}

###############################################################################
# FULL Analysis
###############################################################################
run_full_analysis() {

REPORT_DIR="reports"
REPORT_FILE="$REPORT_DIR/summary.md"
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
  commits_per_author_raw=$(GIT_EDITOR=true git shortlog -s -n --all 2>/dev/null)

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

# ------------------------- NODE (CHARTS) -------------------------
generate_charts

# ----------------------- LLM INTELLIGENT REPORT GENERATOR -----------------------
TOTAL_COMMITS="$total_commits" COMMITS_7="$commits_last7" COMMITS_30="$commits_last30" \
AUTHORS="$commits_per_author_raw" INSERTIONS="$insertions" DELETIONS="$deletions" \
MODIFIED="$most_modified" STALE="$stale_branches" REPORT_PATH="$REPORT_FILE" ZERO="$ZERO_COMMITS" \
node /tool/ai/reportGenerator.js

echo
echo "Full analysis complete!"
echo "Report written to $REPORT_FILE"

} # end full analysis
###############################################################################
# MAIN MENU
###############################################################################
# Non-interactive mode (CI/CD support)
if [ ! -t 0 ]; then
  echo "Non-interactive mode detected. Running full analysis..."
  run_full_analysis
  exit 0
fi
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