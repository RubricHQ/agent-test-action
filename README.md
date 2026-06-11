# RubricHQ Agent Test Action

Run RubricHQ agent test scenarios from GitHub Actions and gate deploys on the verdict. Catch agent regressions before they reach production.

---

## Quick start

```yaml
name: Agent Tests

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  agent-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: noorsy/agent-test-action@v1
        with:
          api_key: ${{ secrets.RUBRICHQ_API_KEY }}
          agent_id: ${{ vars.RUBRICHQ_AGENT_ID }}
          tags: smoke-test
```

The action triggers a test run, polls the RubricHQ API until all scenarios complete, writes a pass/fail summary to the job summary panel, and exits non-zero if the verdict is `failed` — blocking any downstream jobs.

---

## Setup

1. **Create an API key** — open the RubricHQ app, go to **Settings → API Keys**, generate a new key, and copy it.
2. **Save the key as a GitHub secret** — in your repo go to **Settings → Secrets and variables → Actions → New repository secret**, name it `RUBRICHQ_API_KEY`, and paste the key.
3. **Find your agent ID** — open the agent in the RubricHQ app; the ID appears in the URL (`/agents/42/...`).
4. **Save the agent ID as a repo variable** — under **Settings → Secrets and variables → Actions → Variables → New repository variable**, name it `RUBRICHQ_AGENT_ID`.
5. **Tag your scenarios** — in the RubricHQ scenario editor, add tags (e.g. `smoke-test`, `regression`) to the scenarios you want to run in CI.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | RubricHQ API key. Store as a GitHub secret. |
| `agent_id` | Yes | — | Numeric ID of the agent under test. |
| `scenario_ids` | No | `""` | Comma-separated scenario IDs to run. At least one of `scenario_ids` or `tags` is required. |
| `tags` | No | `""` | Comma-separated scenario tags to run. At least one of `scenario_ids` or `tags` is required. |
| `frequency` | No | `"1"` | How many times to run each scenario (1–5). Higher values smooth out flakiness at the cost of run time. |
| `success_threshold` | No | `"100"` | Minimum pass rate percentage (0–100) required for the run to be marked `passed`. |
| `timeout` | No | `"3600"` | Maximum seconds to wait for the test run to complete before the action errors out. |
| `poll_interval` | No | `"15"` | Seconds between status polls while waiting for the run to finish. |
| `channel` | No | `""` | Channel to test over: `phone`, `web`, or `text`. Defaults to the agent's configured channel. |
| `api_url` | No | `"https://api.rubrichq.io"` | RubricHQ API base URL. Override for self-hosted or staging environments. |

---

## Outputs

| Output | Description |
|---|---|
| `test_run_id` | Numeric ID of the triggered test run. |
| `verdict` | Final verdict: `passed` or `failed`. |
| `pass_rate` | Pass rate as a percentage (e.g. `80`). |
| `report_url` | Direct URL to the full report in the RubricHQ app. |

---

## Gating a deploy

Use `needs: agent-tests` to prevent the deploy job from running unless the agent tests pass:

```yaml
name: Test and Deploy

on:
  push:
    branches: [main]

jobs:
  agent-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: noorsy/agent-test-action@v1
        with:
          api_key: ${{ secrets.RUBRICHQ_API_KEY }}
          agent_id: ${{ vars.RUBRICHQ_AGENT_ID }}
          tags: smoke-test
          success_threshold: "80"

  deploy:
    needs: agent-tests
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to production
        run: ./scripts/deploy.sh
```

You can also read the outputs in the deploy job to include the report URL in a Slack notification or deployment record:

```yaml
  deploy:
    needs: agent-tests
    runs-on: ubuntu-latest
    steps:
      - name: Deploy
        run: ./scripts/deploy.sh

      - name: Notify Slack
        run: |
          curl -X POST "${{ secrets.SLACK_WEBHOOK }}" \
            -d '{"text": "Deployed! Agent test report: ${{ needs.agent-tests.outputs.report_url }}"}'
```

---

## Staging → production pipeline

Run tests against your staging agent before promoting to production, using two sequential jobs with different secrets and variables:

```yaml
name: Promote to Production

on:
  workflow_dispatch:

jobs:
  test-staging:
    runs-on: ubuntu-latest
    outputs:
      report_url: ${{ steps.tests.outputs.report_url }}
    steps:
      - id: tests
        uses: noorsy/agent-test-action@v1
        with:
          api_key: ${{ secrets.RUBRICHQ_API_KEY_STAGING }}
          agent_id: ${{ vars.RUBRICHQ_AGENT_ID_STAGING }}
          tags: regression
          frequency: "3"
          success_threshold: "90"

  test-production-canary:
    needs: test-staging
    runs-on: ubuntu-latest
    steps:
      - uses: noorsy/agent-test-action@v1
        with:
          api_key: ${{ secrets.RUBRICHQ_API_KEY_PROD }}
          agent_id: ${{ vars.RUBRICHQ_AGENT_ID_PROD }}
          tags: smoke-test
          success_threshold: "100"

  promote:
    needs: [test-staging, test-production-canary]
    runs-on: ubuntu-latest
    steps:
      - name: Promote staging build to production
        run: ./scripts/promote.sh
```

---

## Troubleshooting

**The action times out before finishing**

Voice scenarios take several minutes each because they involve real phone calls or WebSocket sessions. With `frequency: 3` and 10 scenarios, expect 30+ minutes of run time. Increase the `timeout` input (default is 3600 s / 1 hour). If runs are consistently slow, consider splitting scenarios across multiple workflow jobs using different `tags`.

**"No scenarios matched tags" / zero runs triggered**

Tag strings are matched exactly. Check the tags on your scenarios in the RubricHQ app — they must match character-for-character (case-sensitive). If you are using the `tags` input, make sure there are no extra spaces: `tags: smoke-test` not `tags: smoke-test `. Multiple tags should be comma-separated: `tags: smoke-test,regression`.

**HTTP 402 error when triggering**

Your RubricHQ account is out of test credits. Top up your credits under **Settings → Billing** in the RubricHQ app, then re-run the workflow.

**HTTP 401 error**

The `RUBRICHQ_API_KEY` secret is missing, expired, or was pasted with extra whitespace. Regenerate the key under **Settings → API Keys** and re-save the secret.

**HTTP 404 error**

The `agent_id` does not exist in the account associated with the API key. Double-check the agent ID and that the API key belongs to the correct workspace.

**Pass rate is lower than expected**

Use `frequency: 3` or higher to run each scenario multiple times and smooth out flakiness from real-world voice infrastructure variability. You can also lower `success_threshold` (e.g. `"80"`) to allow for a small number of transient failures without blocking your deploy.
