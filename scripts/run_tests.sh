#!/usr/bin/env bash
# Triggers a RubricHQ test run, polls until the verdict settles, writes a
# job summary, and exits 0 (passed) / 1 (failed) to gate the workflow.
# Uses only tools preinstalled on GitHub runners: bash, curl, python3.
set -euo pipefail

API_URL="${API_URL%/}"

if [[ -z "${API_KEY:-}" || -z "${AGENT_ID:-}" ]]; then
  echo "::error::api_key and agent_id are required" >&2
  exit 1
fi
if [[ -z "${SCENARIO_IDS:-}" ]]; then
  echo "::error::scenario_ids is required" >&2
  exit 1
fi

body=$(python3 - <<'PY'
import json, os

payload = {
    "agent_id": int(os.environ["AGENT_ID"]),
    "frequency": int(os.environ.get("FREQUENCY") or 1),
    "success_threshold": int(os.environ.get("SUCCESS_THRESHOLD") or 100),
    "name": "CI {} {}".format(
        os.environ.get("GITHUB_REPOSITORY", ""),
        (os.environ.get("GITHUB_SHA", "") or "")[:7]).strip(),
    "ci_metadata": {
        "sha": os.environ.get("GITHUB_SHA", ""),
        "branch": os.environ.get("GITHUB_REF_NAME", ""),
        "repo": os.environ.get("GITHUB_REPOSITORY", ""),
        "run_url": "{}/{}/actions/runs/{}".format(
            os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
            os.environ.get("GITHUB_REPOSITORY", ""),
            os.environ.get("GITHUB_RUN_ID", "")),
    },
}
if os.environ.get("SCENARIO_IDS"):
    payload["scenario_ids"] = [int(x) for x in os.environ["SCENARIO_IDS"].split(",") if x.strip()]
if os.environ.get("TAGS"):
    payload["tags"] = [x.strip() for x in os.environ["TAGS"].split(",") if x.strip()]
if os.environ.get("CHANNEL"):
    payload["channel"] = os.environ["CHANNEL"]
print(json.dumps(payload))
PY
)

echo "Triggering test run for agent ${AGENT_ID}..."
response=$(curl -sS -w $'\n%{http_code}' -X POST "${API_URL}/api/public/v1/test_runs" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${body}")
http_code=$(tail -n1 <<< "${response}")
trigger_json=$(sed '$d' <<< "${response}")

if [[ "${http_code}" != 2* ]]; then
  echo "::error::Failed to trigger test run (HTTP ${http_code}): ${trigger_json}" >&2
  exit 1
fi

read -r test_run_id report_url < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["test_run_id"], d.get("report_url", "-"))' <<< "${trigger_json}")

echo "Test run ${test_run_id} started: ${report_url}"
{
  echo "test_run_id=${test_run_id}"
  echo "report_url=${report_url}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

deadline=$(( $(date +%s) + TIMEOUT ))
status_json=""
verdict="pending"

while true; do
  if (( $(date +%s) >= deadline )); then
    echo "::error::Timed out after ${TIMEOUT}s waiting for test run ${test_run_id} (try a larger timeout input)" >&2
    [[ -n "${status_json}" ]] && echo "Last status: ${status_json}"
    exit 1
  fi

  status_json=$(curl -sS "${API_URL}/api/public/v1/test_runs/${test_run_id}" \
    -H "Authorization: Bearer ${API_KEY}")

  read -r verdict progress < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d.get("runs", {})
print(d.get("verdict", "pending"),
      # "completed" counts only successful-status runs; errored calls land in
      # "failed", so runs that are done = completed + failed.
      "{}/{}-done,-{}-failed".format(r.get("completed", 0) + r.get("failed", 0),
                                     r.get("total", "?"), r.get("failed", 0)))' <<< "${status_json}")

  echo "[$(date -u +%H:%M:%S)] verdict=${verdict} (${progress//-/ })"
  [[ "${verdict}" != "pending" ]] && break
  sleep "${POLL_INTERVAL}"
done

# Final report: log + job summary + outputs
STATUS_JSON="${status_json}" python3 - <<'PY'
import json, os

d = json.loads(os.environ["STATUS_JSON"])
runs = d.get("runs", {})
verdict = d.get("verdict", "failed")
pass_rate = d.get("pass_rate")
icon = "✅" if verdict == "passed" else "❌"

lines = [
    f"## {icon} RubricHQ Agent Tests: {verdict.upper()}",
    "",
    f"**Pass rate:** {pass_rate}% (threshold: {d.get('success_threshold')}%)",
    f"**Runs:** {runs.get('passed', 0)} passed / {runs.get('total', 0)} total",
    "",
]
failed = d.get("failed_runs") or []
if failed:
    lines += ["| Run | Scenario | Reason |", "|---|---|---|"]
    lines += [f"| {f.get('run_id')} | {f.get('scenario_name') or '-'} | {f.get('reason') or '-'} |"
              for f in failed]
    lines.append("")
lines.append(f"[View full report]({d.get('report_url')})")

summary = "\n".join(lines)
print(summary)

summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path:
    with open(summary_path, "a") as fh:
        fh.write(summary + "\n")

out = os.environ.get("GITHUB_OUTPUT")
if out:
    with open(out, "a") as fh:
        fh.write(f"verdict={verdict}\n")
        fh.write(f"pass_rate={pass_rate}\n")
PY

if [[ "${verdict}" == "passed" ]]; then
  echo "Agent tests passed."
  exit 0
else
  echo "::error::Agent tests failed — ${report_url}" >&2
  exit 1
fi
