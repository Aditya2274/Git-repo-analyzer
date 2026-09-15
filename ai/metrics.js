const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const REPORT_DIR = path.join(process.cwd(), 'reports');
const METRICS_PATH = path.join(REPORT_DIR, 'metrics.json');
const SECONDS_PER_DAY = 24 * 60 * 60;
const CHURN_WINDOW_DAYS = 30;
const CHURN_DECAY_LAMBDA = 0.05;
const BUS_FACTOR_CRITICAL_THRESHOLD = 4.25;

function run(cmd) {
    try {
        return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
    } catch {
        return '';
    }
}

function quote(value) {
    return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function toInt(value) {
    const parsed = Number.parseInt(String(value).trim(), 10);
    return Number.isFinite(parsed) ? parsed : 0;
}

function toFloat(value) {
    const parsed = Number.parseFloat(String(value).trim());
    return Number.isFinite(parsed) ? parsed : 0;
}

function listTrackedFiles() {
    const output = run('git ls-files -z');
    if (!output) {
        return [];
    }
    return output.split('\0').filter(Boolean);
}

function getCurrentUnixTime() {
    const parsed = toInt(run('date +%s'));
    return parsed > 0 ? parsed : Math.floor(Date.now() / 1000);
}

function getMainBranch() {
    const remoteHead = run('git symbolic-ref --quiet --short refs/remotes/origin/HEAD');
    if (remoteHead) {
        return remoteHead.replace(/^origin\//, '');
    }

    for (const candidate of ['main', 'master', 'trunk']) {
        if (run(`git rev-parse --verify --quiet ${quote(candidate)}`)) {
            return candidate;
        }
    }

    const currentBranch = run('git branch --show-current');
    return currentBranch || 'HEAD';
}

function parseFileHistory(filePath) {
    const history = run(`git log --follow --format=%an%x09%ct -- ${quote(filePath)}`);
    if (!history) {
        return [];
    }

    return history
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
        .map((line) => {
            const [author, timestamp] = line.split('\t');
            return {
                author: author || 'Unknown',
                timestamp: toInt(timestamp),
            };
        })
        .filter((entry) => entry.timestamp > 0);
}

function getFileLoc(filePath) {
    const content = run(`git show HEAD:${quote(filePath)} 2>/dev/null | wc -l`);
    const loc = toInt(content);
    if (loc > 0) {
        return loc;
    }

    if (fs.existsSync(filePath)) {
        const fileContent = fs.readFileSync(filePath, 'utf8');
        return fileContent.split(/\r?\n/).length - 1;
    }

    return 0;
}

function summarizeBusFactor(files, now) {
    const fileSummaries = [];
    const authorSummary = new Map();

    for (const filePath of files) {
        const history = parseFileHistory(filePath);
        if (history.length === 0) {
            continue;
        }

        const totalCommits = history.length;
        const firstAuthor = history[history.length - 1].author;
        const counts = new Map();

        for (const entry of history) {
            counts.set(entry.author, (counts.get(entry.author) || 0) + 1);
        }

        let best = null;
        for (const [author, dl] of counts.entries()) {
            const ac = totalCommits - dl;
            const fa = author === firstAuthor ? 1 : 0;
            const doa = 3.293 + 1.098 * fa + 0.164 * dl - 0.321 * Math.log(1 + ac);
            const share = dl / totalCommits;

            if (!best || doa > best.doa) {
                best = {
                    author,
                    doa,
                    dl,
                    ac,
                    fa,
                    share,
                };
            }

            const authorTotals = authorSummary.get(author) || { fileCount: 0, doaTotal: 0, maxDoa: 0 };
            authorTotals.fileCount += 1;
            authorTotals.doaTotal += doa;
            authorTotals.maxDoa = Math.max(authorTotals.maxDoa, doa);
            authorSummary.set(author, authorTotals);
        }

        if (!best) {
            continue;
        }

        const riskLevel = best.doa >= BUS_FACTOR_CRITICAL_THRESHOLD && best.share >= 0.5
            ? 'critical'
            : best.doa >= 3.75
                ? 'high'
                : 'moderate';

        fileSummaries.push({
            file: filePath,
            topAuthor: best.author,
            doa: Number(best.doa.toFixed(3)),
            firstAuthor: firstAuthor,
            dl: best.dl,
            ac: best.ac,
            share: Number(best.share.toFixed(3)),
            riskLevel,
            commits: totalCommits,
        });
    }

    fileSummaries.sort((a, b) => b.doa - a.doa || b.share - a.share || a.file.localeCompare(b.file));

    const criticalFiles = fileSummaries.filter((entry) => entry.riskLevel === 'critical').slice(0, 10);
    const highRiskFiles = fileSummaries.slice(0, 10);
    const topRisk = fileSummaries[0] || null;

    const authors = Array.from(authorSummary.entries())
        .map(([author, stats]) => ({
            author,
            fileCount: stats.fileCount,
            averageDoa: Number((stats.doaTotal / stats.fileCount).toFixed(3)),
            maxDoa: Number(stats.maxDoa.toFixed(3)),
        }))
        .sort((a, b) => b.averageDoa - a.averageDoa || b.fileCount - a.fileCount || a.author.localeCompare(b.author));

    return {
        formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
        threshold: BUS_FACTOR_CRITICAL_THRESHOLD,
        filesAnalyzed: fileSummaries.length,
        criticalFileCount: criticalFiles.length,
        topRisk,
        criticalFiles,
        highRiskFiles,
        authorSummary: authors.slice(0, 10),
    };
}

function summarizeHotspots(files, now) {
    const hotspotSummaries = [];
    let repoInsertions = 0;
    let repoDeletions = 0;
    let repoLoc = 0;

    for (const filePath of files) {
        const loc = getFileLoc(filePath);
        repoLoc += loc;

        const fileHistory = run(`git log --follow --since='${CHURN_WINDOW_DAYS} days ago' --format=%ct%x09%H --numstat -- ${quote(filePath)}`);
        if (!fileHistory) {
            continue;
        }

        let additions = 0;
        let deletions = 0;
        let commitCount = 0;
        let lastTimestamp = 0;

        for (const line of fileHistory.split('\n')) {
            const trimmed = line.trim();
            if (!trimmed) {
                continue;
            }

            const headerMatch = trimmed.match(/^(\d+)\t([0-9a-f]{7,40})$/i);
            if (headerMatch) {
                commitCount += 1;
                lastTimestamp = Math.max(lastTimestamp, toInt(headerMatch[1]));
                continue;
            }

            const parts = trimmed.split(/\t+/);
            if (parts.length < 2) {
                continue;
            }

            const added = toInt(parts[0]);
            const deleted = toInt(parts[1]);
            if (!Number.isNaN(added)) {
                additions += added;
                repoInsertions += added;
            }
            if (!Number.isNaN(deleted)) {
                deletions += deleted;
                repoDeletions += deleted;
            }
        }

        if (commitCount === 0 && additions === 0 && deletions === 0) {
            continue;
        }

        const churn = loc > 0 ? ((additions + deletions) / loc) * 100 : 0;
        const daysSinceChange = lastTimestamp > 0 ? Math.max(0, Math.floor((now - lastTimestamp) / SECONDS_PER_DAY)) : CHURN_WINDOW_DAYS;
        const hotspotScore = churn * commitCount * Math.exp(-CHURN_DECAY_LAMBDA * daysSinceChange);

        hotspotSummaries.push({
            file: filePath,
            additions,
            deletions,
            loc,
            commitCount,
            daysSinceChange,
            churn: Number(churn.toFixed(3)),
            hotspotScore: Number(hotspotScore.toFixed(3)),
        });
    }

    hotspotSummaries.sort((a, b) => b.hotspotScore - a.hotspotScore || b.churn - a.churn || a.file.localeCompare(b.file));

    return {
        windowDays: CHURN_WINDOW_DAYS,
        decayLambda: CHURN_DECAY_LAMBDA,
        totalLoc: repoLoc,
        totalInsertions: repoInsertions,
        totalDeletions: repoDeletions,
        topHotspots: hotspotSummaries.slice(0, 10),
    };
}

function summarizeBranchDrift(now, mainBranch) {
    const branches = run('git for-each-ref --format=%(refname:short) refs/heads/')
        .split('\n')
        .map((line) => line.trim())
        .filter(Boolean)
        .filter((branch) => branch !== mainBranch);

    const branchSummaries = [];

    for (const branch of branches) {
        const mergeBase = run(`git merge-base ${quote(mainBranch)} ${quote(branch)}`);
        if (!mergeBase) {
            continue;
        }

        const divergenceTimestamp = toInt(run(`git show -s --format=%ct ${quote(mergeBase)}`));
        if (divergenceTimestamp <= 0) {
            continue;
        }

        const daysSinceDivergence = Math.max(0, Math.floor((now - divergenceTimestamp) / SECONDS_PER_DAY));
        const mainCommitsSince = toInt(run(`git rev-list --count ${quote(mergeBase)}..${quote(mainBranch)}`));
        const syncCommits = toInt(run(`git rev-list --count --merges ${quote(mergeBase)}..${quote(branch)}`));
        const drift = Math.max(0, daysSinceDivergence * Math.max(0, mainCommitsSince - syncCommits));

        branchSummaries.push({
            branch,
            daysSinceDivergence,
            mainCommitsSince,
            syncCommits,
            drift,
            riskLevel: drift >= 100 ? 'critical' : drift >= 40 ? 'high' : 'moderate',
        });
    }

    branchSummaries.sort((a, b) => b.drift - a.drift || b.daysSinceDivergence - a.daysSinceDivergence || a.branch.localeCompare(b.branch));

    return {
        mainBranch,
        branchesAnalyzed: branchSummaries.length,
        staleBranches: branchSummaries.slice(0, 10),
    };
}

function buildEmptyMetrics(now, mainBranch) {
    return {
        generatedAt: new Date(now * 1000).toISOString(),
        repository: {
            mainBranch,
            commitHistoryAvailable: false,
        },
        busFactor: {
            formula: 'DOA(e,f)=3.293+1.098(FA)+0.164(DL)-0.321ln(1+AC)',
            threshold: BUS_FACTOR_CRITICAL_THRESHOLD,
            filesAnalyzed: 0,
            criticalFileCount: 0,
            topRisk: null,
            criticalFiles: [],
            highRiskFiles: [],
            authorSummary: [],
        },
        hotspots: {
            windowDays: CHURN_WINDOW_DAYS,
            decayLambda: CHURN_DECAY_LAMBDA,
            totalLoc: 0,
            totalInsertions: 0,
            totalDeletions: 0,
            topHotspots: [],
        },
        branchDrift: {
            mainBranch,
            branchesAnalyzed: 0,
            staleBranches: [],
        },
    };
}

function main() {
    const now = getCurrentUnixTime();
    const mainBranch = getMainBranch();

    fs.mkdirSync(REPORT_DIR, { recursive: true });

    if (!run('git rev-parse --verify HEAD')) {
        const emptyMetrics = buildEmptyMetrics(now, mainBranch);
        fs.writeFileSync(METRICS_PATH, `${JSON.stringify(emptyMetrics, null, 2)}\n`, 'utf8');
        console.log(`Wrote empty metrics to ${METRICS_PATH}`);
        return;
    }

    const files = listTrackedFiles();
    const busFactor = summarizeBusFactor(files, now);
    const hotspots = summarizeHotspots(files, now);
    const branchDrift = summarizeBranchDrift(now, mainBranch);

    const metrics = {
        generatedAt: new Date(now * 1000).toISOString(),
        repository: {
            mainBranch,
            trackedFiles: files.length,
            commitHistoryAvailable: true,
        },
        busFactor,
        hotspots,
        branchDrift,
    };

    fs.writeFileSync(METRICS_PATH, `${JSON.stringify(metrics, null, 2)}\n`, 'utf8');
    console.log(`Wrote repository metrics to ${METRICS_PATH}`);
    console.log(`Bus factor files analyzed: ${busFactor.filesAnalyzed}`);
    console.log(`Hotspots analyzed: ${hotspots.topHotspots.length}`);
    console.log(`Branches analyzed: ${branchDrift.branchesAnalyzed}`);
}

main();
