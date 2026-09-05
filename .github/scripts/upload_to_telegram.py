#!/usr/bin/env python3
import html
import json
import os
import subprocess
import sys

def main():
    bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "@bruhperidot").strip()
    module_zip = os.environ.get("MODULE_ZIP", "").strip()
    zip_name = os.environ.get("ZIP_NAME", "").strip()

    if not bot_token:
        print("::notice title=Telegram Upload Notice::TELEGRAM_BOT_TOKEN is not configured in repository secrets. Flashable module ZIP was built successfully.")
        print("To enable automatic module uploads to https://t.me/bruhperidot:")
        print("  1. Open Telegram and message @BotFather to create a bot (/newbot).")
        print("  2. Copy the HTTP API token provided by BotFather.")
        print("  3. Add the bot to your channel (https://t.me/bruhperidot) as an Administrator with 'Post Messages' permission.")
        print("  4. In GitHub -> BruhMount repo -> Settings -> Secrets and variables -> Actions -> New repository secret:")
        print("     Name: TELEGRAM_BOT_TOKEN")
        print("     Value: <your bot token>")
        sys.exit(0)

    if not module_zip or not os.path.isfile(module_zip):
        print(f"::error::Module ZIP file not found at: {module_zip}")
        sys.exit(1)

    if not zip_name:
        zip_name = os.path.basename(module_zip)

    # Extract git metadata
    try:
        short_hash = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
    except Exception:
        short_hash = "head"

    try:
        commit_count = subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True).strip()
    except Exception:
        commit_count = "1"

    # Extract version from module.prop
    version = "v2.1.0-enhanced"
    if os.path.isfile("module/module.prop"):
        with open("module/module.prop", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("version="):
                    version = line.split("=", 1)[1].strip()
                    break

    branch = os.environ.get("GITHUB_REF_NAME", "master")

    # Extract changelog
    try:
        commits = subprocess.check_output(
            ["git", "log", "--no-merges", "-n", "5", "--pretty=format:• %s (%h)"],
            text=True
        ).strip()
    except Exception:
        commits = "• Continuous update"

    if not commits:
        try:
            commits = subprocess.check_output(
                ["git", "log", "-n", "5", "--pretty=format:• %s (%h)"],
                text=True
            ).strip()
        except Exception:
            commits = "• Automated release build"

    raw_caption = f"""📦 BruhMount Flashable Module
──────────────────────────────
Version : {version}
Branch  : {branch}
Commit  : {short_hash}
Target  : KernelSU / APatch

Changelog:
{commits}
──────────────────────────────"""

    # Telegram caption limit: 1024 characters total.
    # Keep raw text under 950 characters before tags.
    if len(raw_caption) > 950:
        raw_caption = raw_caption[:947] + "..."

    escaped_caption = f"<pre><code>{html.escape(raw_caption)}</code></pre>"

    print(f"[+] Monospace Caption ({len(escaped_caption)} chars):\n{escaped_caption}\n")
    print(f"[+] Uploading {zip_name} to Telegram chat: {chat_id}...")

    # Upload using curl for standard multipart handling
    curl_cmd = [
        "curl", "-s", "-w", "\nHTTP_STATUS:%{http_code}",
        "-X", "POST", f"https://api.telegram.org/bot{bot_token}/sendDocument",
        "-F", f"chat_id={chat_id}",
        "-F", f"document=@{module_zip};filename={zip_name}",
        "--form-string", f"caption={escaped_caption}",
        "-F", "parse_mode=HTML"
    ]

    res = subprocess.run(curl_cmd, capture_output=True, text=True)
    out_lines = res.stdout.strip().split("\n")
    http_status = "0"
    body_lines = []
    for line in out_lines:
        if line.startswith("HTTP_STATUS:"):
            http_status = line.split(":", 1)[1].strip()
        else:
            body_lines.append(line)
    body = "\n".join(body_lines).strip()

    print(f"HTTP Status: {http_status}")
    print(f"Response: {body}")

    try:
        resp_json = json.loads(body)
        if http_status == "200" and resp_json.get("ok"):
            print(f"🎉 Successfully uploaded {zip_name} to {chat_id}!")
            sys.exit(0)
        else:
            desc = resp_json.get("description", "Unknown error")
            print(f"::error title=Telegram Upload Failed::Telegram API error: {desc} (HTTP {http_status})")
            print(f"Please ensure your bot has been added as an Administrator to {chat_id} with 'Post Messages' permission.")
            sys.exit(1)
    except Exception as e:
        print(f"::error title=Telegram Upload Failed::Failed to parse response: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
