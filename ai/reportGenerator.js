const fs = require('fs');
const path = require('path');
require("dotenv").config();
const { buildPrompt } = require("./prompt");

function loadMetrics(reportPath) {
    const metricsPath = path.join(path.dirname(reportPath), 'metrics.json');
    try {
        return JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
    } catch {
        return {
            repository: {},
            busFactor: { criticalFiles: [], highRiskFiles: [], authorSummary: [] },
            hotspots: { topHotspots: [] },
            branchDrift: { staleBranches: [] },
        };
    }
}

function formatItems(items, formatter) {
    if (!Array.isArray(items) || items.length === 0) {
        return '- None detected';
    }

    return items.map((item) => `- ${formatter(item)}`).join('\n');
}

(async () => {
    const reportPath = process.env.REPORT_PATH || "reports/summary.md";
    const isZero = process.env.ZERO === "true";
    const metrics = loadMetrics(reportPath);

    // Helper to write the standard static report (Used as our CI/CD fallback)
    const writeStaticReport = (note = "") => {
        let content = `# Git Repository Analysis Report\n`;
        content += `Generated on: ${new Date().toUTCString()}\n\n`;
        if (note) content += `> **Note:** ${note}\n\n`;
        if (isZero) content += `**No commits found — charts will be skipped.**\n\n`;
        content += `## Deterministic Metric Summary\n`;
        content += `- Main branch: ${metrics.repository?.mainBranch || metrics.branchDrift?.mainBranch || 'unknown'}\n`;
        content += `- Tracked files analyzed: ${metrics.repository?.trackedFiles || 0}\n`;
        content += `- Bus factor formula: ${metrics.busFactor?.formula || 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)'}\n`;
        content += `- Bus factor critical threshold: ${metrics.busFactor?.threshold ?? 'n/a'}\n`;
        content += `- Churn window: ${metrics.hotspots?.windowDays || 30} days\n`;
        content += `- Churn decay lambda: ${metrics.hotspots?.decayLambda ?? 0.05}\n\n`;

        content += `## Bus Factor / Degree of Authorship\n`;
        content += formatItems(metrics.busFactor?.criticalFiles, (item) => `${item.file} -> ${item.topAuthor} (DOA ${item.doa}, share ${(item.share * 100).toFixed(1)}%, risk ${item.riskLevel})`);
        content += `\n\n`;

        content += `## Code Churn / Hotspot Volatility\n`;
        content += `- Repository totals: ${metrics.hotspots?.totalInsertions || 0} insertions, ${metrics.hotspots?.totalDeletions || 0} deletions, ${metrics.hotspots?.totalLoc || 0} LOC\n`;
        content += formatItems(metrics.hotspots?.topHotspots, (item) => `${item.file} -> score ${item.hotspotScore}, churn ${item.churn}%, commits ${item.commitCount}, days since change ${item.daysSinceChange}`);
        content += `\n\n`;

        content += `## Branch Staleness / Feature Drift\n`;
        content += `- Branches analyzed: ${metrics.branchDrift?.branchesAnalyzed || 0}\n`;
        content += formatItems(metrics.branchDrift?.staleBranches, (item) => `${item.branch} -> drift ${item.drift}, days since divergence ${item.daysSinceDivergence}, main commits since split ${item.mainCommitsSince}, sync merges ${item.syncCommits}, risk ${item.riskLevel}`);
        content += `\n\n`;

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
        console.log("GROQ_API_KEY not detected. Using standard static report format.");
        writeStaticReport();
        return;
    }

    console.log("GROQ_API_KEY detected! Performing AI architectural analysis via LangChain...");


    // 3. Invoke Groq LLM
    try {
        const { generateGroqReport } =require("./providers/groqProvider");
        const prompt = buildPrompt(metrics);

        console.log("⏳ Analyzing metrics with Groq LLM...");
        
        let finalMarkdown = await generateGroqReport(prompt);
        // Remove accidental markdown fences if generated by the LLM
        finalMarkdown = finalMarkdown.replace(/^```markdown\n?|^```\n?/, "").replace(/\n?```$/, "");

        // Append visual charts section at the end of the AI report
        finalMarkdown += `\n\n## 6. Visual Activity Charts\n`;
        if (!isZero) {
            finalMarkdown += `### Commits Per Author\n![chart](charts/commits_per_author.png)\n\n`;
            finalMarkdown += `### Daily Commit Activity\n![chart](charts/daily_commit_activity.png)\n`;
        } else {
            finalMarkdown += `**Charts unavailable — repository has no commits.**\n`;
        }

        fs.writeFileSync(reportPath, finalMarkdown, 'utf8');
        console.log("AI-powered architectural report written to " + reportPath);

    } catch (error) {
        console.error("Error communicating with Groq LLM:", error.message);
        console.log("Falling back to standard static markdown report...");
        writeStaticReport("AI Analysis failed (" + error.message + ") — generated standard fallback report.");
    }
})();