import json
import os
import subprocess
import sys
import html

zip_path = os.environ.get("ZIP_PATH")
if not zip_path or not os.path.exists(zip_path):
    sys.exit(f"ERROR: The file '{zip_path}' DOES NOT EXIST.")

token = os.environ.get("BOT_TOKEN", "").strip()
if token.lower().startswith("bot"):
    token = token[3:].strip()
chat_id = os.environ.get("CHAT_ID", "").strip()
topic_id = os.environ.get("TOPIC_ID", "")

def sanitize(text: str) -> str:
    if not text:
        return ""
    if token:
        text = text.replace(token, "***REDACTED_TOKEN***")
    return text

if token and (os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS")):
    print(f"::add-mask::{token}")
msg = os.environ.get("COMMIT_MESSAGE", "Manual build dispatch").split('\n')[0].strip()
commit_url = os.environ.get("COMMIT_URL", f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}")
run_url = os.environ["RUN_URL"]
run_number = os.environ["RUN_NUMBER"]
branch = os.environ.get("GITHUB_REF_NAME", "unknown")

title = f"NoMount CI Build ({branch} branch)"
run_text = f"#ci_{run_number}"

if len(msg) > 800:
    msg = msg[:797] + "..."

caption = (
    f"<b>{html.escape(title)}</b>\n"
    f"{html.escape(run_text)}\n"
    f"<pre>{html.escape(msg)}</pre>\n"
    f"<a href=\"{commit_url}\">Commit</a> | <a href=\"{run_url}\">Workflow</a>"
)

curl_cmd = [
    "curl", "-sS", "-X", "POST",
    f"https://api.telegram.org/bot{token}/sendDocument",
    "-F", f"chat_id={chat_id}",
    "--form-string", f"caption={caption}",
    "-F", "parse_mode=HTML",
    "-F", f"document=@{zip_path}"
]

if topic_id:
    curl_cmd.extend(["-F", f"message_thread_id={topic_id}"])

print(f"Uploading {zip_path} to Telegram...")
result = subprocess.run(curl_cmd, capture_output=True, text=True)

if result.returncode != 0:
    sys.exit(f"Critical error: cURL failed (Exit code {result.returncode})\n{sanitize(result.stderr)}")

try:
    response = json.loads(result.stdout)
    if not response.get("ok"):
        sys.exit(f"Error returned by Telegram API:\n{sanitize(json.dumps(response, indent=2))}")
    print("Artifact successfully uploaded to Telegram!")
except json.JSONDecodeError:
    sys.exit(f"Telegram response is not valid JSON:\n{sanitize(result.stdout)}")
