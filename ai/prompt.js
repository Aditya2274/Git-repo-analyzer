function formatItems(items, formatter) {
    if (!Array.isArray(items) || items.length === 0) {
        return '- None detected';
    }

    return items.map((item) => `- ${formatter(item)}`).join('\n');
}

function buildPrompt(metrics = {}) {
    const repository = metrics.repository || {};
    const busFactor = metrics.busFactor || {};
    const hotspots = metrics.hotspots || {};
    const branchDrift = metrics.branchDrift || {};

    return `You are a Principal DevOps Engineer and Senior Tech Lead performing an architectural review of a Git repository.

The metrics below are computed deterministically from Git history. Treat them as ground truth and use them to explain risk, not to guess at ownership or volatility.

Do not just repeat the raw numbers. Interpret the computed formulas, identify the highest-risk files and branches, and explain what the metrics imply for maintainability and delivery safety.

--- DETERMINISTIC GIT METRICS ---

Repository:
- Main branch: ${repository.mainBranch || branchDrift.mainBranch || 'unknown'}
- Tracked files analyzed: ${repository.trackedFiles || 0}
- Metrics generated at: ${metrics.generatedAt || new Date().toUTCString()}

Bus Factor / Degree of Authorship:
- Formula: ${busFactor.formula || 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)'}
- Critical threshold: ${busFactor.threshold ?? 'n/a'}
- Files analyzed: ${busFactor.filesAnalyzed || 0}
- Critical files:
${formatItems(busFactor.criticalFiles, (item) => `${item.file} -> ${item.topAuthor} (DOA ${item.doa}, share ${(item.share * 100).toFixed(1)}%, risk ${item.riskLevel})`)}
- Top risk files:
${formatItems(busFactor.highRiskFiles, (item) => `${item.file} -> ${item.topAuthor} (DOA ${item.doa}, commits ${item.commits}, share ${(item.share * 100).toFixed(1)}%)`)}

Code Churn / Hotspot Volatility:
- Window: ${hotspots.windowDays || 30} days
- Decay lambda: ${hotspots.decayLambda ?? 0.05}
- Repository totals: ${hotspots.totalInsertions || 0} insertions, ${hotspots.totalDeletions || 0} deletions, ${hotspots.totalLoc || 0} LOC
- Top hotspots:
${formatItems(hotspots.topHotspots, (item) => `${item.file} -> score ${item.hotspotScore}, churn ${item.churn}%, commits ${item.commitCount}, days since change ${item.daysSinceChange}`)}

Branch Staleness / Feature Drift:
- Main branch: ${branchDrift.mainBranch || repository.mainBranch || 'unknown'}
- Branches analyzed: ${branchDrift.branchesAnalyzed || 0}
- Top drift branches:
${formatItems(branchDrift.staleBranches, (item) => `${item.branch} -> drift ${item.drift}, days since divergence ${item.daysSinceDivergence}, main commits since split ${item.mainCommitsSince}, sync merges ${item.syncCommits}, risk ${item.riskLevel}`)}

-------------------

Output ONLY the raw Markdown content for the report.

Do not include introductory chatter or markdown code fences (\`\`\`markdown).

Structure the markdown report with these exact sections:

# 🧠 AI Architectural Repository Analysis

*Generated on: ${new Date().toUTCString()} via Groq LLM (${process.env.GROQ_MODEL || 'groq/compound-mini'})*

## 1. 🚀 Velocity & Maintenance Momentum

(Analyze total vs recent commits. Is the repo active, accelerating, or dormant?)

## 2. 👥 Contributor Dynamics & Bus Factor

(Analyze commit distribution and the computed DOA risk. Is work balanced or reliant on a single person?)

## 3. 🔥 Code Churn & Hotspot Analysis

(Analyze the computed churn, hotspot scores, and most modified files. Identify potential refactoring needs or bottlenecks.)

## 4. 🧹 Repository Hygiene & Recommendations

(Analyze branch drift and stale branches, then give actionable DevOps advice.)

## 5. 📊 Raw Metrics Summary

(List the raw numbers and stats here as bullet points for factual verification.)
`;
}

module.exports = {
    buildPrompt
};