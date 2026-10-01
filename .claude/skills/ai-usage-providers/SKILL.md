---
name: ai-usage-providers
description: Reference for MyHub's AI Usage feature — the UsageProvider protocol, snapshot model, and the exact endpoints/auth/fields for Claude plan, Claude Code logs, Anthropic Admin, OpenAI Admin, ChatGPT/Codex plan, Codex logs, OpenRouter, AWS Bedrock (SigV4/CloudWatch/Cost Explorer), and custom/LiteLLM endpoints. Use when implementing or debugging anything under Features/AIUsage/.
---

# AI Usage providers

Read `docs/PLAN.md` §4.5 first. Security rules are in the `macos-app-security` skill, and concurrency rules in `swift-concurrency-safety`.

## Contract
```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var allowedHosts: Set<String> { get }   // enforced by HTTPClient
    func fetch(now: Date) async throws -> UsageSnapshot
}
enum UsageError: Error { case notConfigured, unauthorized, expiredToken, rateLimited(retryAfter: Duration?),
                          badResponse(status: Int), decoding(String), unsupported }
```
- Providers are stateless `Sendable` structs. State (backoff, last snapshot) lives in `actor UsageEngine`.
- Percentages are normalised to `usedFraction` in `0...1` (APIs return 0–100 **or** 0–1, so check per provider).
- Money is `Decimal` + ISO currency. Never use `Double` for money.
- Every decoder is tested against a **recorded, redacted fixture** in `Tests/MyHubTests/Fixtures/`.

## Endpoints

### 1. Claude Pro/Max plan (unofficial)
- `GET https://api.anthropic.com/api/oauth/usage`
- Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: MyHub/<ver>`
- Token: Keychain service `Claude Code-credentials` → JSON `claudeAiOauth.accessToken` (`expiresAt` is in ms).
- **Verified live 2026-09-30.** `five_hour`, `seven_day` (+ nullable `seven_day_opus`/`seven_day_sonnet`/`seven_day_oauth_apps`) → `{ utilization: 0–100 (float), resets_at: "2026-09-30T20:30:00.130999+00:00" (6-digit fraction), limit_dollars, used_dollars, … }`. Also `limits[]` (`kind: session|weekly_all`, `percent`, `severity`, `is_active`), `spend { used: {amount_minor, currency, exponent}, limit, enabled }`, `seven_day_breakdown.rows[] {key, display_name, percent}`, and many codenamed keys (mostly null) — ignore unknown keys, never guess at them.
- Keychain JSON `claudeAiOauth`: `accessToken`, `refreshToken`, `expiresAt` (ms, int), `scopes`, `subscriptionType` ("pro", "max"), `rateLimitTier`.
- Known to return 429 in bursts. Poll at most every 5 min when visible, and back off.

### 2. Claude Code local logs (estimated)
- Roots: `$CLAUDE_CONFIG_DIR/projects`, `~/.claude/projects`, `~/.config/claude/projects`.
- `**/*.jsonl`, one JSON per line. Use lines with `type == "assistant"` and `message.usage`: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, plus `message.model` and `timestamp`.
- **Verified live:** one message is written on several lines (one per content block) with the same `message.id` + `requestId`; ~2.4 lines per message, and in ~4% the `output_tokens` grows between lines (streaming). Dedupe by that key keeping the max output — counting lines doubles the totals. `usage.cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}` splits cache writes by TTL (1h writes cost 2× input). Skip `model` values like `<synthetic>`.
- Aggregate: last 5 h, today, last 7 days, by model. Cost from the built-in `PriceTable` (+ `~/Library/Application Support/MyHub/pricing.json` overrides), shown as "API-equivalent", marked estimated.
- Opt-in live check: `MYHUB_LIVE=1 swift test --filter LiveLogs`.

### 3. Anthropic API org (official)
- `GET https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=…&ending_at=…&bucket_width=1d&group_by[]=model`
- `GET https://api.anthropic.com/v1/organizations/cost_report?starting_at=…&ending_at=…`
- Headers: `x-api-key: sk-ant-admin…`, `anthropic-version: 2023-06-01`. Paginated with `has_more`/`next_page` (pass as `page`).
- Cost `amount` is a **decimal string in cents** (`"123.45"` = $1.23); usage results: `uncached_input_tokens`, `cache_read_input_tokens`, `cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens`, `output_tokens`, `model` (with `group_by[]=model`). `1d` buckets: default 7, max 31. Implemented in `AdminProviders.swift`.

### 4. OpenAI API org (official)
- `GET https://api.openai.com/v1/organization/costs?start_time=<unix>&bucket_width=1d&group_by=line_item`
- `GET https://api.openai.com/v1/organization/usage/completions?start_time=<unix>&bucket_width=1d&group_by=model`
- Header: `Authorization: Bearer sk-admin-…`. Paginated with `has_more`/`next_page`. Costs are `amount.value` (number — some clients report strings, accept both) + `amount.currency` (lowercase `usd`). Usage: `input_tokens` includes `input_cached_tokens`.

### 5. ChatGPT / Codex plan (unofficial)
- `GET https://chatgpt.com/backend-api/wham/usage`
- Headers: `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`, `User-Agent: codex-cli`
- Auth file: `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id` (else the `chatgpt_account_id` claim in the JWT).
- Response: `plan_type`, `rate_limit.primary_window` (≈5 h) / `secondary_window` (weekly), each `{ used_percent, limit_window_seconds, reset_after_seconds, reset_at (unix s) }`, optional `credits`.

### 6. Codex local logs
- `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Look for `event_msg` payloads of `type: "token_count"` with token totals and a `rate_limits` snapshot (`primary`/`secondary` with `used_percent`, window minutes, reset). Verify the field names on a real file first. Treat the result as "last seen".

### 7. OpenRouter (official)
- `GET https://openrouter.ai/api/v1/key` → `data.usage`, `data.limit`, `data.limit_remaining`, `data.limit_reset`, `data.is_free_tier`
- `GET https://openrouter.ai/api/v1/credits` → `data.total_credits`, `data.total_usage`
- Header: `Authorization: Bearer <key>`

### 8. AWS Bedrock (official)
- CloudWatch `GetMetricData`: `POST https://monitoring.<region>.amazonaws.com/`, JSON protocol: header `Content-Type: application/x-amz-json-1.0`, `X-Amz-Target: GraniteServiceVersion20100801.GetMetricData`, **or** the query protocol (`Action=GetMetricData&Version=2010-08-01`). Implemented with the JSON protocol and `SEARCH` expressions (one series per ModelId, Label = model id, timestamps in epoch seconds) — **not yet verified against a live account**.
  - Namespace `AWS/Bedrock`, metrics `InputTokenCount`, `OutputTokenCount`, `Invocations`, dimension `ModelId`, stat `Sum`, period 3600/86400. Discover model ids with `ListMetrics`.
- Cost Explorer (optional, **$0.01 per call**, max 1/hour): `POST https://ce.us-east-1.amazonaws.com/`, `X-Amz-Target: AWSInsightsIndexService.GetCostAndUsage`, filter `SERVICE` = `Amazon Bedrock` (the service name can vary per model vendor, so use `DimensionValues` discovery), metric `UnblendedCost`, granularity `DAILY`/`MONTHLY`.
- SigV4: own `SigV4Signer` (CryptoKit `HMAC<SHA256>`). Canonical request → string-to-sign → signing key `kDate→kRegion→kService→"aws4_request"`. Include `x-amz-security-token` when a session token exists. **Test with AWS's published SigV4 test-suite vectors.**
- Minimal IAM policy to show users: `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics`, optionally `ce:GetCostAndUsage`.

### 9. Custom endpoint / LiteLLM
- User config: `url`, `method` (GET), `authHeader` (for example `Authorization` with `Bearer {secret}`, or `x-api-key`), a secret in Keychain, and a mapping of key paths (`"data.spend"`, `"windows[0].used_percent"`) → `used`, `limit`, `spend`, `currency`, `resetAt`, `percentScale` (1 or 100).
- LiteLLM preset: `GET {base}/key/info` → `info.spend`, `info.max_budget`, `info.budget_reset_at`.
- Evaluate key paths with a tiny safe evaluator (dot + `[index]` only; no scripting).
