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
console.log("Chart directory:", CHART_DIR);

const { ChartJSNodeCanvas } = require("chartjs-node-canvas");
console.log("✓ ChartJS loaded");

const createCanvas = (w, h) => new ChartJSNodeCanvas({ width: w, height: h, backgroundColour: 'white' });

(async () => {
    try {
        console.log("===== CHART GENERATION STARTED =====");
    // Author chart
    const authorDataRaw = run("GIT_EDITOR=true git shortlog -s -n --all");
    console.log("Author data:");
    console.log(authorDataRaw);
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
        console.log("✓ commits_per_author.png created");
    }

    // Daily activity
    const datesRaw = run("git log --date=short --pretty=format:%ad");
    console.log("Dates:");
    console.log(datesRaw);
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
        console.log("✓ daily_commit_activity.png created");
    }
        console.log("Files inside charts:");
        console.log(fs.readdirSync(CHART_DIR));
        console.log("Author chart exists:",
                    fs.existsSync(`${CHART_DIR}/commits_per_author.png`)
                    );

    console.log(
        "Daily chart exists:",
        fs.existsSync(`${CHART_DIR}/daily_commit_activity.png`)
    );
        console.log("===== CHART GENERATION COMPLETED =====");
    } catch (err) {
        console.error("CHART ERROR:");
        console.error(err.stack || err);
        process.exit(1);
    }
})();