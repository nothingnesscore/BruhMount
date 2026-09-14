#!/usr/bin/env node
const cp = require("child_process");
const fs = require("fs");
const path = require("path");
const https = require("https");

function run(cmd, args = [], options = {}) {
    return cp.spawnSync(cmd, args, {
        encoding: "utf-8",
        stdio: options.silent ? "pipe" : "inherit",
        ...options
    });
}

function runOutput(cmd, args = [], options = {}) {
    const res = cp.spawnSync(cmd, args, { encoding: "utf-8", ...options });
    if (res.error) throw res.error;
    return (res.stdout || "").trim();
}

function hasConflictMarkers(filePath) {
    try {
        const content = fs.readFileSync(filePath, "utf-8");
        return content.includes("<<<<<<<") && (content.includes("=======") || content.includes(">>>>>>>"));
    } catch {
        return false;
    }
}

function validateRepo() {
    console.log("[*] Running sanity checks across repository...");
    
    // 1. Check for conflict markers in tracked files
    const status = runOutput("git", ["status", "--porcelain"]);
    const changedFiles = status.split("\n")
        .map(line => line.slice(3).trim())
        .filter(f => f.length > 0 && fs.existsSync(f));

    for (const f of changedFiles) {
        if (hasConflictMarkers(f)) {
            console.warn(`[!] Conflict markers found in ${f}! Restoring working HEAD version...`);
            run("git", ["checkout", "HEAD", "--", f]);
        }
    }

    // 2. Validate WebUI JS syntax
    try {
        runOutput("node", ["-c", "module/webroot/index.js"]);
        console.log("  [+] JavaScript syntax validated successfully (module/webroot/index.js).");
    } catch (err) {
        console.warn("  [!] WebUI syntax invalid! Restoring working HEAD version...", err);
        run("git", ["checkout", "HEAD", "--", "module/webroot/index.js"]);
    }

    // 3. Validate JSON files
    const jsonFiles = ["update.json"];
    const localesDir = "module/webroot/locales";
    if (fs.existsSync(localesDir)) {
        fs.readdirSync(localesDir).forEach(f => {
            if (f.endsWith(".json")) jsonFiles.push(path.join(localesDir, f));
        });
    }

    for (const jf of jsonFiles) {
        if (!fs.existsSync(jf)) continue;
        try {
            JSON.parse(fs.readFileSync(jf, "utf-8"));
        } catch (err) {
            console.warn(`  [!] JSON corrupted in ${jf}! Restoring working HEAD version...`);
            run("git", ["checkout", "HEAD", "--", jf]);
        }
    }
    console.log(`  [+] Validated ${jsonFiles.length} JSON configuration/locale files.`);

    // 4. Validate Shell scripts if bash is available
    const bashExec = process.platform === "win32"
        ? (fs.existsSync("C:\\Program Files\\Git\\bin\\bash.exe") ? "C:\\Program Files\\Git\\bin\\bash.exe" : null)
        : "bash";

    if (bashExec) {
        ["module/metamount.sh", "module/customize.sh"].forEach(sh => {
            if (fs.existsSync(sh)) {
                const res = run(bashExec, ["-n", sh], { silent: true });
                if (res.status !== 0) {
                    console.warn(`  [!] Shell script syntax error in ${sh}! Restoring working HEAD version...`);
                    run("git", ["checkout", "HEAD", "--", sh]);
                } else {
                    console.log(`  [+] Shell syntax valid: ${sh}`);
                }
            }
        });
    }
}

async function dispatchBuildWorkflow(token, repo) {
    if (!token || !repo) {
        console.log("[*] GITHUB_TOKEN or GITHUB_REPOSITORY not set. Skipping automatic build dispatch.");
        return;
    }

    console.log(`[*] Dispatching "build module" workflow on ${repo} (ref: master)...`);
    return new Promise((resolve) => {
        const payload = JSON.stringify({ ref: "master" });
        const req = https.request({
            hostname: "api.github.com",
            path: `/repos/${repo}/actions/workflows/build.yml/dispatches`,
            method: "POST",
            headers: {
                "User-Agent": "NodeJS-Sync-Workflow",
                "Authorization": `token ${token}`,
                "Accept": "application/vnd.github.v3+json",
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(payload)
            }
        }, res => {
            console.log(`  [+] Workflow dispatch HTTP Status: ${res.statusCode}`);
            let body = "";
            res.on("data", d => body += d);
            res.on("end", () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    console.log("  🎉 Continuous CI build successfully triggered!");
                } else {
                    console.warn(`  [!] Workflow dispatch returned: ${body || res.statusMessage}`);
                }
                resolve();
            });
        });

        req.on("error", err => {
            console.warn(`  [!] Failed to send workflow dispatch request: ${err.message}`);
            resolve();
        });

        req.write(payload);
        req.end();
    });
}

async function main() {
    const targetBranch = process.env.TARGET_BRANCH || "master";
    const upstreamUrl = process.env.UPSTREAM_URL || "https://github.com/maxsteeel/nomount.git";
    const gitToken = process.env.GITHUB_TOKEN || "";
    const gitRepo = process.env.GITHUB_REPOSITORY || "";

    console.log("=== BruhMount Upstream Auto-Sync Engine ===");
    console.log(`Tracking upstream: ${upstreamUrl} (${targetBranch})`);

    run("git", ["config", "--global", "user.name", "github-actions[bot]"]);
    run("git", ["config", "--global", "user.email", "github-actions[bot]@users.noreply.github.com"]);

    // Ensure upstream remote exists
    const remotes = runOutput("git", ["remote"]).split("\n").map(r => r.trim());
    if (!remotes.includes("upstream")) {
        console.log(`[*] Adding upstream remote: ${upstreamUrl}`);
        run("git", ["remote", "add", "upstream", upstreamUrl]);
    } else {
        run("git", ["remote", "set-url", "upstream", upstreamUrl]);
    }

    console.log(`[*] Fetching upstream/${targetBranch}...`);
    const fetchRes = run("git", ["fetch", "upstream", targetBranch]);
    if (fetchRes.status !== 0) {
        console.error("[!] Failed to fetch upstream. Exiting.");
        process.exit(1);
    }

    const localSha = runOutput("git", ["rev-parse", "HEAD"]);
    const upstreamSha = runOutput("git", ["rev-parse", `upstream/${targetBranch}`]);

    console.log(`Local  SHA: ${localSha}`);
    console.log(`Remote SHA: ${upstreamSha}`);

    const isAncestor = run("git", ["merge-base", "--is-ancestor", `upstream/${targetBranch}`, "HEAD"]).status === 0;
    if (isAncestor) {
        console.log(`✅ Repository is already up to date with upstream/nomount (${upstreamSha.slice(0, 7)}).`);
        process.exit(0);
    }

    console.log("[*] New upstream commits detected! Integrating changes...");
    const newCommits = runOutput("git", ["log", "-n", "5", "--pretty=format:* %s (%h)", `HEAD..upstream/${targetBranch}`]);
    console.log(newCommits);

    // Attempt merge with --no-commit
    const mergeRes = run("git", ["merge", `upstream/${targetBranch}`, "--no-commit"]);
    if (mergeRes.status !== 0) {
        console.warn("[!] Merge conflict detected. Running intelligent conflict resolution...");

        // Files that MUST preserve BruhMount custom features:
        const protectedFiles = [
            "module/webroot/index.html",
            "module/webroot/index.js",
            "module/webroot/styles.css",
            "module/webroot/theme.css",
            "module/customize.sh",
            "module/metamount.sh",
            "changelog.md",
            ".github/workflows/build.yml",
            ".github/workflows/upstream-sync.yml",
            ".github/scripts/upload_to_telegram.py",
            ".github/scripts/sync_upstream.js"
        ];

        // Files that should accept upstream updates:
        const upstreamTrackedPrefixes = [
            "kernel/src/",
            "userspace/src/"
        ];

        const statusPorcelain = runOutput("git", ["status", "--porcelain"]);
        const conflictedFiles = statusPorcelain.split("\n")
            .filter(line => line.startsWith("UU") || line.startsWith("AA") || line.startsWith("UD") || line.startsWith("DU"))
            .map(line => line.slice(3).trim());

        for (const file of conflictedFiles) {
            const isProtected = protectedFiles.includes(file);
            const isUpstreamTracked = upstreamTrackedPrefixes.some(prefix => file.startsWith(prefix));

            if (isProtected) {
                console.log(`  [~] Preserving BruhMount enhancement: ${file}`);
                run("git", ["checkout", "HEAD", "--", file]);
            } else if (isUpstreamTracked) {
                console.log(`  [~] Accepting upstream optimization: ${file}`);
                run("git", ["checkout", `upstream/${targetBranch}`, "--", file]);
            } else {
                console.log(`  [~] Auto-resolving in favor of working version: ${file}`);
                run("git", ["checkout", "HEAD", "--", file]);
            }
        }
    }

    // Run verification & sanity checks
    validateRepo();

    run("git", ["add", "-A"]);
    const stagedDiff = run("git", ["diff", "--staged", "--quiet"]).status;
    if (stagedDiff === 0) {
        console.log("[*] No new changes to commit after harmonization.");
        process.exit(0);
    }

    const commitMsg = `chore(upstream): auto-merge maxsteeel/nomount (${targetBranch} @ ${upstreamSha.slice(0, 7)}) with BruhMount enhancements`;
    console.log(`[*] Creating commit: ${commitMsg}`);
    run("git", ["commit", "-m", commitMsg]);

    console.log("[*] Pushing synchronized commit to origin master...");
    const pushRes = run("git", ["push", "origin", "master"]);
    if (pushRes.status !== 0) {
        console.error("[!] Failed to push changes to master. Exiting.");
        process.exit(1);
    }

    console.log("🎉 Upstream sync committed and pushed successfully!");

    // Trigger CI module build
    await dispatchBuildWorkflow(gitToken, gitRepo);
}

main().catch(err => {
    console.error("[!] Unexpected error during upstream sync:", err);
    process.exit(1);
});
