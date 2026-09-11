function buildPrompt() {

    return `You are a Principal DevOps Engineer and Senior Tech Lead performing an architectural review of a Git repository.

Based on the following Git metrics, generate a comprehensive, professional Markdown analysis report.

Do not just repeat the raw numbers—interpret them! Analyze development velocity, contributor distribution (bus factor), code churn, architectural hotspots, and branch hygiene.

--- GIT METRICS ---

Total Commits: ${process.env.TOTAL_COMMITS}

Commits in Last 7 Days: ${process.env.COMMITS_7}

Commits in Last 30 Days: ${process.env.COMMITS_30}

Code Churn: ${process.env.INSERTIONS} lines added, ${process.env.DELETIONS} lines removed

Commits per Author:
${process.env.AUTHORS}

Most Modified Files (Hotspots):
${process.env.MODIFIED}

Stale Branches (>30 days inactive):
${process.env.STALE}

-------------------

Output ONLY the raw Markdown content for the report.

Do not include introductory chatter or markdown code fences (\`\`\`markdown).

Structure the markdown report with these exact sections:

# 🧠 AI Architectural Repository Analysis

*Generated on: ${new Date().toUTCString()} via Groq LLM (${process.env.GROQ_MODEL || "groq/compound-mini"})*

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
}

module.exports = {
    buildPrompt
};