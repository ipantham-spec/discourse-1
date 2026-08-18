# Moderation Samples — API calls, requests & responses

Copy-paste, runnable samples for every scenario in the Discourse ⇄ forums
moderation loop. All request/response bodies below are **real captures** from the
local stack (Discourse `:3000`, forums `:8080`, real Azure OpenAI text engine).

See [`INTEGRATION.md`](INTEGRATION.md) for the architecture and flow diagrams.

---

## 0. Setup — signing helper

Every hop is authenticated with `sha256=HMAC-SHA256(secret, rawBody)`. Two
secrets are involved:

| Secret | Signs | Discourse setting | forums property |
|---|---|---|---|
| **webhook secret** | Discourse → forums (event / text-check / nudge-metrics) | `custom_webhooks_secret` | `discourse.moderation.webhook-secret` |
| **callback secret** | forums → Discourse (verdict) | `custom_webhooks_callback_secret` | `discourse.moderation.callback-secret` |

```bash
# --- paste once per shell ---
FORUMS="http://localhost:8080/forums/api/v1/discourse/moderation"
DISCOURSE="http://localhost:3000"

# Pull the local secrets straight from the running Discourse (no hardcoding):
cd /path/to/discourse
WEBHOOK_SECRET=$(bin/rails runner 'print SiteSetting.custom_webhooks_secret')
CALLBACK_SECRET=$(bin/rails runner 'print SiteSetting.custom_webhooks_callback_secret')

# Sign a body with a given secret → prints the header value.
sign() {  # usage: sign "<secret>" "<body>"
  printf '%s' "$2" | python3 -c \
    "import hmac,hashlib,sys;print('sha256='+hmac.new('$1'.encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())"
}
```

> The signature is over the **exact raw bytes** you send. Build the body once in a
> variable and sign that same variable — don't reformat between signing and
> sending.

---

## 1. Text nudge — clean text (Flow A)

Nothing is flagged; the composer lets the post through.

```bash
BODY='{"event_type":"topic","actor":{"sso_id":"1002920570207","locale":"en","trust_level":2},"text":{"title":"My title","raw":"thanks everyone, lovely community here"}}'
curl -s "$FORUMS/text-check" \
  -H 'Content-Type: application/json' \
  -H "X-Discourse-Event-Signature: $(sign "$WEBHOOK_SECRET" "$BODY")" \
  --data "$BODY"
```

**Response `200`**
```json
{
  "violation_found": false,
  "can_publish": true,
  "category": "Neither",
  "severity": null,
  "confidence": 0.99,
  "flagged_terms": null,
  "reasons": null,
  "reasoning": "The message is polite and appreciative, with no rude, threatening, discriminatory, spammy, or policy-violating content."
}
```
**Discourse:** post is created normally, no dialog.

---

## 2. Text nudge — abusive text (Flow A)

The engine flags it; the composer shows the **Edit / Post anyway** dialog.

```bash
BODY='{"event_type":"topic","actor":{"sso_id":"1002920570207","locale":"en","trust_level":2},"text":{"title":"My title","raw":"you are an asshole and a pathetic loser"}}'
curl -s "$FORUMS/text-check" \
  -H 'Content-Type: application/json' \
  -H "X-Discourse-Event-Signature: $(sign "$WEBHOOK_SECRET" "$BODY")" \
  --data "$BODY"
```

**Response `200`**
```json
{
  "violation_found": true,
  "can_publish": false,
  "category": "Abuse",
  "severity": null,
  "confidence": 0.99,
  "flagged_terms": ["asshole", "pathetic loser"],
  "reasons": null,
  "reasoning": "The post contains direct personal insults aimed at another user, which is rude and abusive rather than constructive disagreement.",
  "nudge_message": "The post contains direct personal insults aimed at another user, which is rude and abusive rather than constructive disagreement."
}
```

**Discourse (composer):** shows the nudge dialog.
- **Edit** → save is cancelled, composer stays open, nothing is posted.
- **Post anyway** → the post is created (→ **Scenario 5**, async re-check).

The plugin normalises this to what the composer consumes:
```json
{ "can_publish": false, "nudge_message": "...", "suggested_rewrite": null,
  "category": "Abuse", "event_id": "<uuid>" }
```

---

## 3. Text engine unreachable (Flow A, fail-open)

If forums is down or the engine errors, the check **fails open** so composing is
never blocked.

```bash
# (stop forums, or point text_check_url at a dead port) then in the composer:
# the plugin's /custom-webhooks/moderation/check returns:
```
```json
{ "can_publish": true }
```
**Discourse:** post allowed (no nudge).

---

## 4. Nudge response recorded (Flow A analytics)

After the author picks Edit or Post-anyway, the composer fires a
fire-and-forget metric.

```bash
BODY='{"event_id":"33333333-3333-3333-3333-333333333333","source":"DISCOURSE","action":"post_anyway","category":"Abuse","actor":{"sso_id":"1002920570207","locale":"en","trust_level":2},"recorded_at":"2026-08-18T15:10:00Z"}'
curl -s -w '\n%{http_code}\n' "$FORUMS/nudge-metrics" \
  -H 'Content-Type: application/json' \
  -H "X-Discourse-Event-Signature: $(sign "$WEBHOOK_SECRET" "$BODY")" \
  --data "$BODY"
```

**Response `202`**
```json
{"status":"recorded"}
```
`action` is `edit` or `post_anyway`. A bad signature returns `401`; any store
error is swallowed as `202 {"status":"error"}` so it never blocks.

---

## 5. "Post anyway" abusive text → async re-check hides + reviews (Flows A→B)

The post is published, then the async event re-scores the text; a violation
**hides the post from the public** and raises a `/review` item.

### 5a. The async event (Discourse → forums)

In production this is SQS; locally it's the `dev-intake` HTTP shim.

```bash
EID=$(uuidgen)
BODY=$(printf '{"event_id":"%s","event":"post_created","event_type":"topic","post_id":12345,"topic_id":6789,"post_url":"'"$DISCOURSE"'/t/x/6789/1","callback_url":"'"$DISCOURSE"'/custom-webhooks/moderation/callback","actor":{"sso_id":"1002920570207","locale":"en","trust_level":2},"text":{"title":"My title","raw":"you are all a bunch of idiots and morons, shut up"},"images":[],"has_images":false}' "$EID")
curl -s -o /dev/null -w 'intake: %{http_code}\n' "$FORUMS/dev-intake" \
  -H 'Content-Type: application/json' \
  -H "X-Discourse-Event-Signature: $(sign "$WEBHOOK_SECRET" "$BODY")" \
  --data "$BODY"
```
**Response:** `200` (body empty; the verdict arrives later via the callback).

### 5b. The verdict callback (forums → Discourse)

forums posts this back to `callback_url` (signed with the **callback** secret):

```bash
CB=$(printf '{"event_id":"%s","moderation_id":"5c897632-2b69-4627-b78c-5421ac5bbf9f","post_id":12345,"topic_id":6789,"results":{"text":{"violation_found":true,"can_publish":false,"category":"Abuse","confidence":0.99,"flagged_terms":["idiots","morons"],"reasoning":"Direct insults aimed at other users."}}}' "$EID")
curl -s -w '\n%{http_code}\n' "$DISCOURSE/custom-webhooks/moderation/callback" \
  -H 'Content-Type: application/json' \
  -H "X-Forums-Signature: $(sign "$CALLBACK_SECRET" "$CB")" \
  --data "$CB"
```

**Response `200`**
```json
{"status":"applied","post_id":12345,"action":"review"}
```

**Discourse does:** hides the post (`hide!`) + creates a
`ReviewableCustomWebhooksModeration`. Result on the post:
- `hidden = true` — removed from public view.
- Author & staff still see it (greyed, "edit to make visible").
- Appears in `/review` with category **Abuse**, confidence, flagged terms, reasoning.

**Replay** (same `event_id` again) is idempotent:
```json
{"status":"noop","post_id":12345}
```

---

## 6. Clean reply/edit → async re-check no-ops (Flow B)

Same async path, clean text. forums returns `text.violation_found:false`; the
callback publishes/leaves the post as-is.

```bash
CB='{"event_id":"clean-1","moderation_id":"m-clean","post_id":12345,"topic_id":6789,"results":{"text":{"violation_found":false,"can_publish":true,"category":"Neither"}}}'
curl -s -w '\n%{http_code}\n' "$DISCOURSE/custom-webhooks/moderation/callback" \
  -H 'Content-Type: application/json' \
  -H "X-Forums-Signature: $(sign "$CALLBACK_SECRET" "$CB")" \
  --data "$CB"
```
**Response `200`** → `{"status":"applied","post_id":12345,"action":"published"}`
**Discourse:** post stays visible; no review item.

---

## 7. Image hold-pending — clean (Flow C)

Post with an image is held hidden on creation; forums scans with CTD and calls
back `CLEAN`.

**Callback body — clean image:**
```json
{
  "event_id": "img-clean-1",
  "moderation_id": "uuid",
  "post_id": 12345,
  "topic_id": 6789,
  "results": { "image": { "verdict": "CLEAN", "status": "complete" } },
  "timestamp": 1787058599825
}
```
**Response `200`** → `{"status":"applied","post_id":12345,"action":"published"}`
**Discourse:** the held post is **unhidden** (published).

> `images[].url` sent in the event is a presigned S3 URL in production (or a
> localhost `/uploads/...` URL in local dev) — the scanner fetches it directly.
> See INTEGRATION.md §1 "How images reach the scanner".

---

## 8. Image — CSAM in a public post (Flow C)

**Callback body — CSAM:**
```json
{
  "event_id": "img-csam-1",
  "moderation_id": "uuid",
  "post_id": 12345,
  "topic_id": 6789,
  "results": { "image": { "verdict": "CSAM", "batch_ids": ["..."], "status": "complete" } },
  "timestamp": 1787058599825
}
```
**Response `200`** → `{"status":"applied","post_id":12345,"action":"destroyed"}`
**Discourse:** post is **destroyed** + audited; a T&S case is filed. No `/review`
item (Khoros parity — public CSAM is removed silently).

---

## 9. Image — CSAM in a private message (Flow C)

Same CSAM verdict, but the post is in a PM (`event_type:"pm"`). Discourse keeps
it hidden and routes it to staff-scoped `/review`.

**Response `200`** → `{"status":"applied","post_id":12345,"action":"review"}`

---

## 10. Error cases

### 10a. Bad signature — forums intake → `401`
```bash
curl -s -o /dev/null -w '%{http_code}\n' "$FORUMS/dev-intake" \
  -H 'Content-Type: application/json' \
  -H "X-Discourse-Event-Signature: sha256=deadbeef" \
  --data "$BODY"     # → 401
```

### 10b. Duplicate event_id — forums intake → `409`
```bash
# POST the same signed BODY from 5a twice; the second returns:
# → 409  (deduped, not retried)
```

### 10c. Bad signature — Discourse callback → `401`
```bash
curl -s -w '\n%{http_code}\n' "$DISCOURSE/custom-webhooks/moderation/callback" \
  -H 'Content-Type: application/json' \
  -H "X-Forums-Signature: sha256=deadbeef" \
  --data "$CB"
```
```json
{"errors":["invalid signature"]}
```

### 10d. Unknown post — Discourse callback → `404`
```json
{"errors":["unknown post"]}
```

---

## 11. Scenario ↔ endpoint ↔ result cheat sheet

| # | Scenario | Endpoint(s) | Response | Discourse action |
|---|---|---|---|---|
| 1 | Clean text | `POST /text-check` | `200 can_publish:true` | Post allowed |
| 2 | Abusive text | `POST /text-check` | `200 can_publish:false` | Nudge dialog (Edit / Post anyway) |
| 3 | Engine down | `POST /text-check` | `200 can_publish:true` (fail-open) | Post allowed |
| 4 | Nudge choice | `POST /nudge-metrics` | `202 recorded` | Analytics row |
| 5 | Post anyway → violation | `dev-intake` → `callback` | `200 action:review` | **Hide** + `/review` |
| 6 | Clean reply/edit | `dev-intake` → `callback` | `200 action:published` | No-op, stays visible |
| 7 | Clean image | `dev-intake` → `callback` | `200 action:published` | Held post unhidden |
| 8 | CSAM public image | `dev-intake` → `callback` | `200 action:destroyed` | Destroy + T&S case |
| 9 | CSAM in PM | `dev-intake` → `callback` | `200 action:review` | Keep hidden + `/review` |
| 10a | Bad sig (intake) | `dev-intake` | `401` | none |
| 10b | Duplicate event | `dev-intake` | `409` | none |
| 10c | Bad sig (callback) | `callback` | `401` | none |
| 10d | Unknown post | `callback` | `404` | none |

---

## 12. One-shot local verification (Discourse side)

```bash
cd /path/to/discourse
# create a profane post, watch the async loop hide it + queue review
bin/rails runner '
  u = User.find_by(username: "<author>")
  p = PostCreator.create!(u, topic_id: <topic_id>, raw: "you are all idiots and morons")
  puts "created post_id=#{p.id} hidden=#{p.hidden}"'        # hidden=false at creation
sleep 8
bin/rails runner 'p = Post.find(<post_id>);
  puts "hidden=#{p.hidden} reviewables=#{Reviewable.where(target_id: p.id).count}"'
# expect: hidden=true  reviewables=1
```
