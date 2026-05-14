#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="$ROOT_DIR/.sync-token"
WORKER_URL="$(defaults read com.techfanseric.aiquotabar cloudSyncEndpointURL 2>/dev/null || true)"

if [[ -z "${WORKER_URL}" ]]; then
  WORKER_URL="https://ai-quota-bar-sync.techfanseric.workers.dev"
fi

if [[ ! -f "$TOKEN_FILE" ]]; then
  osascript -e 'display alert "AI Quota Bar" message "Missing cloudflare/.sync-token. Open Settings and copy the sync token, or redeploy the Worker secret."'
  exit 1
fi

TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"
REPORT="$TMPDIR/ai-quota-bar-remote-data.html"
SAMPLES_JSON="$TMPDIR/ai-quota-bar-samples.json"
DEVICES_JSON="$TMPDIR/ai-quota-bar-devices.json"

curl --retry 3 --retry-delay 2 -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "$WORKER_URL/v1/quota-samples?limit=300" > "$SAMPLES_JSON"

curl --retry 3 --retry-delay 2 -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "$WORKER_URL/v1/devices" > "$DEVICES_JSON"

python3 - "$SAMPLES_JSON" "$DEVICES_JSON" "$REPORT" "$WORKER_URL" <<'PY'
import html
import json
import sys
from datetime import datetime

samples_path, devices_path, report_path, worker_url = sys.argv[1:5]

with open(samples_path, "r", encoding="utf-8") as f:
    samples = json.load(f).get("samples", [])

with open(devices_path, "r", encoding="utf-8") as f:
    devices = json.load(f).get("devices", [])

def cell(value):
    if value is None:
        return ""
    return html.escape(str(value))

def pct(sample):
    total = sample.get("current_interval_total") or 0
    remaining = sample.get("current_interval_remaining") or 0
    if total <= 0:
        return ""
    return f"{remaining / total * 100:.1f}%"

rows = "\n".join(
    f"""
    <tr>
      <td>{cell(s.get("sampled_at"))}</td>
      <td>{cell(s.get("provider"))}</td>
      <td>{cell(s.get("account_name"))}</td>
      <td>{cell(s.get("model_name"))}</td>
      <td>{cell(s.get("current_interval_remaining"))}</td>
      <td>{cell(s.get("current_interval_total"))}</td>
      <td>{cell(pct(s))}</td>
      <td>{cell(s.get("reset_end_time"))}</td>
    </tr>
    """
    for s in samples
)

device_rows = "\n".join(
    f"""
    <tr>
      <td>{cell(d.get("id"))}</td>
      <td>{cell(d.get("last_seen_at"))}</td>
      <td>{cell(d.get("created_at"))}</td>
    </tr>
    """
    for d in devices
)

generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

doc = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AI Quota Bar Remote Data</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; color: #1f2328; }}
    h1 {{ font-size: 24px; margin: 0 0 8px; }}
    h2 {{ font-size: 16px; margin: 28px 0 10px; }}
    .meta {{ color: #6e7781; font-size: 13px; margin-bottom: 18px; }}
    table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
    th, td {{ border-bottom: 1px solid #d8dee4; padding: 8px 10px; text-align: left; vertical-align: top; }}
    th {{ background: #f6f8fa; font-weight: 600; position: sticky; top: 0; }}
    code {{ background: #f6f8fa; border-radius: 4px; padding: 2px 5px; }}
  </style>
</head>
<body>
  <h1>AI Quota Bar Remote Data</h1>
  <div class="meta">Worker: <code>{cell(worker_url)}</code> · Generated: {cell(generated_at)} · Samples: {len(samples)}</div>

  <h2>Devices</h2>
  <table>
    <thead><tr><th>Device ID</th><th>Last seen</th><th>Created</th></tr></thead>
    <tbody>{device_rows or '<tr><td colspan="3">No devices yet.</td></tr>'}</tbody>
  </table>

  <h2>Recent Quota Samples</h2>
  <table>
    <thead>
      <tr>
        <th>Sampled at</th><th>Provider</th><th>Account</th><th>Model</th>
        <th>Remaining</th><th>Total</th><th>%</th><th>Reset end</th>
      </tr>
    </thead>
    <tbody>{rows or '<tr><td colspan="8">No samples yet. Refresh quota in the app once cloud backup is enabled.</td></tr>'}</tbody>
  </table>
</body>
</html>"""

with open(report_path, "w", encoding="utf-8") as f:
    f.write(doc)
PY

open "$REPORT"
