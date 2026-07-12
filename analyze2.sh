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
if [ "$ZERO_COMMITS" = false ]; then
node - <<'JS_GENERATOR'
const fs = require('fs');
const { execSync } = require('child_process');

function run(cmd) {
    try {
        return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
    } catch {
        return "";
    }
}

const CHART_DIR = "reports/charts";
fs.mkdirSync(CHART_DIR, { recursive: true });

let ChartJSNodeCanvas;
try {
    ChartJSNodeCanvas = require('chartjs-node-canvas').ChartJSNodeCanvas;
} catch (e) {
    execSync("npm install --no-save chartjs-node-canvas chart.js", { stdio: 'inherit' });
    ChartJSNodeCanvas = require('chartjs-node-canvas').ChartJSNodeCanvas;
}

const createCanvas = (w, h) => new ChartJSNodeCanvas({ width: w, height: h, backgroundColour: 'white' });

(async () => {
    // Author chart
    const authorDataRaw = run("GIT_EDITOR=true git shortlog -s -n --all");
    if (authorDataRaw) {
        const authors = [];
        const commits = [];
        authorDataRaw.split('\n').forEach(line => {
            const trimmed = line.trim();
            if (!trimmed) return;
            const parts = trimmed.split(/\s+/);
            const count = parseInt(parts[0], 10);
            const name = parts.slice(1).join(' ');
            if (!isNaN(count) && name) {
                commits.push(count);
                authors.push(name);
            }
        });

        const barConfig = {
            type: 'bar',
            data: {
                labels: authors,
                datasets: [{
                    label: 'Commits per Author',
                    data: commits,
                    backgroundColor: 'rgba(54, 162, 235, 0.7)',
                    borderColor: 'rgb(54, 162, 235)',
                    borderWidth: 1
                }]
            },
            options: {
                plugins: {
                    title: { display: true, text: 'Commits Per Author', font: { size: 16 } },
                    legend: { display: false }
                },
                scales: {
                    x: { ticks: { maxRotation: 30, minRotation: 30 } },
                    y: { beginAtZero: true, ticks: { stepSize: 1 } }
                }
            }
        };

        const canvasAuthor = createCanvas(800, 400);
        const imageBuffer = await canvasAuthor.renderToBuffer(barConfig);
        fs.writeFileSync(`${CHART_DIR}/commits_per_author.png`, imageBuffer);
    }

    // Daily activity
    const datesRaw = run("git log --date=short --pretty=format:%ad");
    if (datesRaw) {
        const dates = datesRaw.split('\n').map(d => d.trim()).filter(Boolean);
        const counts = {};
        dates.forEach(d => {
            counts[d] = (counts[d] || 0) + 1;
        });
        const sortedDays = Object.keys(counts).sort();
        const y = sortedDays.map(d => counts[d]);

        const lineConfig = {
            type: 'line',
            data: {
                labels: sortedDays,
                datasets: [{
                    label: 'Daily Commit Activity',
                    data: y,
                    borderColor: 'rgb(54, 162, 235)',
                    backgroundColor: 'rgba(54, 162, 235, 0.5)',
                    tension: 0.1,
                    pointRadius: 4
                }]
            },
            options: {
                plugins: {
                    title: { display: true, text: 'Daily Commit Activity', font: { size: 16 } },
                    legend: { display: false }
                },
                scales: {
                    x: { ticks: { maxRotation: 30, minRotation: 30 } },
                    y: { beginAtZero: true, ticks: { stepSize: 1 } }
                }
            }
        };

        const canvasDaily = createCanvas(1000, 400);
        const imageBuffer = await canvasDaily.renderToBuffer(lineConfig);
        fs.writeFileSync(`${CHART_DIR}/daily_commit_activity.png`, imageBuffer);
    }
})();
JS_GENERATOR
fi

# ----------------------- LLM INTELLIGENT REPORT GENERATOR -----------------------
TOTAL_COMMITS="$total_commits" COMMITS_7="$commits_last7" COMMITS_30="$commits_last30" \
AUTHORS="$commits_per_author_raw" INSERTIONS="$insertions" DELETIONS="$deletions" \
MODIFIED="$most_modified" STALE="$stale_branches" REPORT_PATH="$REPORT_FILE" ZERO="$ZERO_COMMITS" \
node - <<'JS_LLM_REPORT'
const fs = require('fs');
const { execSync } = require('child_process');
require("dotenv").config();
console.log(process.version);
console.log(require.resolve("@langchain/groq"));
(async () => {
    const reportPath = process.env.REPORT_PATH || "reports/summary.md";
    const isZero = process.env.ZERO === "true";

    // Helper to write the standard static report (Used as our CI/CD fallback)
    const writeStaticReport = (note = "") => {
        let content = `# Git Repository Analysis Report\n`;
        content += `Generated on: ${new Date().toUTCString()}\n\n`;
        if (note) content += `> **Note:** ${note}\n\n`;
        if (isZero) content += `**No commits found — charts will be skipped.**\n\n`;
        content += `## Summary\n`;
        content += `- Total Commits: ${process.env.TOTAL_COMMITS}\n`;
        content += `- Commits last 7 days: ${process.env.COMMITS_7}\n`;
        content += `- Commits last 30 days: ${process.env.COMMITS_30}\n\n`;
        content += `## Commits Per Author\n${process.env.AUTHORS}\n\n`;
        content += `## Code Changes\n`;
        content += `- Lines Added: ${process.env.INSERTIONS}\n`;
        content += `- Lines Removed: ${process.env.DELETIONS}\n\n`;
        content += `## Most Modified Files\n${process.env.MODIFIED}\n\n`;
        content += `## Stale Branches\n${process.env.STALE}\n\n`;
        content += `## Charts\n`;
        if (!isZero) {
            content += `### Commits Per Author\n![chart](charts/commits_per_author.png)\n\n`;
            content += `### Daily Commit Activity\n![chart](charts/daily_commit_activity.png)\n`;
        } else {
            content += `**Charts unavailable — repository has no commits.**\n`;
        }
        fs.writeFileSync(reportPath, content, 'utf8');
    };

    // 1. If no GROQ_API_KEY is present, fallback without installing npm packages
    if (!process.env.GROQ_API_KEY) {
        console.log("ℹ️  GROQ_API_KEY not detected. Using standard static report format.");
        writeStaticReport();
        return;
    }

    console.log("🤖 GROQ_API_KEY detected! Performing AI architectural analysis via LangChain...");


    // 3. Invoke Groq LLM
    try {
        require('dotenv').config();
        const { ChatGroq } = require("@langchain/groq");
        console.log("Model:", process.env.GROQ_MODEL || "llama3-8b-8192");
        const model = new ChatGroq({
            apiKey: process.env.GROQ_API_KEY,
            model: process.env.GROQ_MODEL || "llama3-8b-8192",
            temperature: 0.5,
        });

        const prompt = `You are a Principal DevOps Engineer and Senior Tech Lead performing an architectural review of a Git repository.
Based on the following Git metrics, generate a comprehensive, professional Markdown analysis report.
Do not just repeat the raw numbers—interpret them! Analyze development velocity, contributor distribution (bus factor), code churn, architectural hotspots, and branch hygiene.

--- GIT METRICS ---
Total Commits: ${process.env.TOTAL_COMMITS}
Commits in Last 7 Days: ${process.env.COMMITS_7}
Commits in Last 30 Days: ${process.env.COMMITS_30}
Code Churn: ${process.env.INSERTIONS} lines added,${process.env.DELETIONS} lines removed
Commits per Author:
${process.env.AUTHORS}

Most Modified Files (Hotspots):
${process.env.MODIFIED}

Stale Branches (>30 days inactive):
${process.env.STALE}
-------------------

Output ONLY the raw Markdown content for the report. Do not include introductory chatter or markdown code fences (\`\`\`markdown).
Structure the markdown report with these exact sections:
# 🧠 AI Architectural Repository Analysis
*Generated on: ${new Date().toUTCString()} via Groq LLM (${process.env.GROQ_MODEL || "llama3-8b-8192"})*

## 1. 🚀 Velocity & Maintenance Momentum
(Analyze total vs recent commits. Is the repo active, accelerating, or dormant?)

## 2. 👥 Contributor Dynamics & Bus Factor
(Analyze commit distribution. Is work balanced or reliant on a single person?)

## 3. 🔥 Code Churn & Hotspot Analysis
(Analyze additions/deletions and most modified files. Identify potential refactoring needs or bottlenecks.)

## 4. 🧹 Repository Hygiene & Recommendations
(Analyze stale branches and overall workflow health. Give actionable DevOps advice.)

## 5. 📊 Raw Metrics Summary
(List the raw numbers and stats here as bullet points for factual verification.)
`;

        console.log("⏳ Analyzing metrics with Groq LLM...");
        const response = await model.invoke(prompt);
        
        let finalMarkdown = response.content.trim();
        // Remove accidental markdown fences if generated by the LLM
        finalMarkdown = finalMarkdown.replace(/^```markdown\n?|^```\n?/, "").replace(/\n?```$/, "");

        // Append visual charts section at the end of the AI report
        finalMarkdown += `\n\n## 6. 📈 Visual Activity Charts\n`;
        if (!isZero) {
            finalMarkdown += `### Commits Per Author\n![chart](charts/commits_per_author.png)\n\n`;
            finalMarkdown += `### Daily Commit Activity\n![chart](charts/daily_commit_activity.png)\n`;
        } else {
            finalMarkdown += `**Charts unavailable — repository has no commits.**\n`;
        }

        fs.writeFileSync(reportPath, finalMarkdown, 'utf8');
        console.log("✨ AI-powered architectural report written to " + reportPath);

    } catch (error) {
        console.error("⚠️ Error communicating with Groq LLM:", error.message);
        console.log("Falling back to standard static markdown report...");
        writeStaticReport("AI Analysis failed (" + error.message + ") — generated standard fallback report.");
    }
})();
JS_LLM_REPORT

echo
echo "Full analysis complete!"
echo "Report written to $REPORT_FILE"

} # end full analysis
###############################################################################
# MAIN MENU
###############################################################################
# 🔥 Non-interactive mode (CI/CD support)
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