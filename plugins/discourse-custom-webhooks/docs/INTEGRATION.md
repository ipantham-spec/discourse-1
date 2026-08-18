# Discourse ⇄ forums — Moderation Integration (end to end)

How the **Discourse** plugin (`discourse-custom-webhooks`) and the **forums**
service moderate Discourse content together. The forums service reuses its
existing moderation engines (Azure OpenAI text, CTD image/CSAM); the Discourse
plugin is the counterpart that emits events, runs the composer nudge, and
applies verdicts.

- Forums-side guide (engines, SQS, class map): `forums/src/main/java/.../discourse/README.md`
- Discourse plugin reference: [`../README.md`](../README.md)
- Design/review: https://developer.ea.com/display/WWCE/Discourse+webhook

> **Who owns what**
> - **Discourse plugin** — emits signed events, runs the pre-publish composer
>   nudge, receives the verdict callback, and applies it (publish / review /
>   destroy). Renders the `/review` queue item.
> - **forums** — verifies the event, runs the moderation engines, and calls back
>   a signed verdict. Nothing on the Khoros path changes.

---

## 1. The three flows

There are **three** moderation flows. Text is fast and gated inline; images are
slow and gated async. A newer async **text re-check** closes the "Post anyway"
gap so a published violation still reaches a moderator.

| # | Flow | When | Blocking? | Visibility after a violation |
|---|---|---|---|---|
| A | **Text nudge** (pre-publish) | As the author hits Reply | Yes (sync, in the composer) | Post not created (Edit) or created then re-checked (Post anyway → B) |
| B | **Text re-check** (post-publish) | After the post is created/edited | No (async) | **Hidden from public** + queued for review |
| C | **Image hold-pending** | After a post with images is created | No (async) | **Held hidden** until a clean verdict |

### Flow A — Text nudge (synchronous, pre-publish)

Scored **before** the post exists; the verdict returns in the HTTP response so
the composer can nudge the author. This is the only user-visible, Khoros-style
"soft nudge".

```
Composer (Discourse)
  → POST /custom-webhooks/moderation/check          (plugin route; signs body with custom_webhooks_secret)
    → POST {text_check_url}                          (forums /api/v1/discourse/moderation/text-check; verifies signature)
      → TextModerationPromptService → Azure OpenAI
    ← { violation_found, can_publish, category, nudge_message, ... }
  ← can_publish=false → dialog: [Edit] or [Post anyway]
      Edit        → save cancelled, composer stays open
      Post anyway → post is created (→ Flow B)
  → POST /custom-webhooks/moderation/nudge-metric    (fire-and-forget analytics → nudge_metrics_url)
```

Fails **open**: any check error (or blank `text_check_url`) returns
`can_publish: true`, so composing is never hard-blocked.

### Flow B — Text re-check (asynchronous, post-publish)

Every eligible `post_created` / `post_edited` also fires an async event. forums
re-scores the text with the **same engine** as Flow A. If it is a violation, the
plugin **hides the post from the public** and raises a `/review` item. The
author and staff still see the hidden post (greyed, with an "edit to make
visible" notice); a moderator then restores or removes it — standard Discourse
flag behaviour.

```
Discourse (post already created & visible)
  → Jobs::CustomWebhooksEmitEvent → signed event → forums (SQS in prod / dev-intake locally)
    → DiscourseModerationOrchestrator → DiscourseTextModerationAdapter → Azure OpenAI
  ← POST /custom-webhooks/moderation/callback  { results.text.violation_found: true, ... }
Discourse: violation → hide post + raise ReviewableCustomWebhooksModeration
           clean     → no-op (nothing to do)
```

### Flow C — Image hold-pending (asynchronous, callback)

If `custom_webhooks_hold_images_pending` is on, a post with images is **hidden
immediately** on creation, then forums scans the images with CTD and calls back.

```
Discourse (post with images → hidden pending)
  → signed event → forums (SQS / dev-intake)
    → DiscourseModerationOrchestrator → DiscourseImageScanner → CTD (CSAM)
  ← POST /custom-webhooks/moderation/callback  { results.image.verdict: "CLEAN" | "CSAM" }
Discourse: CLEAN → publish (unhide)
           CSAM public post → destroy + audit (no review item, Khoros parity)
           CSAM in a PM     → keep hidden + /review (staff-scoped)
```

> Flows B and C share **one** async event and **one** callback. The event
> payload always carries `text` **and** any `images`; forums scores whatever is
> present and returns `results.text` and/or `results.image`. The plugin applies
> both in a single verdict.

---

## 2. Endpoints (who calls whom)

### Discourse plugin routes (inbound to Discourse)

| Route | Caller | Auth | Purpose |
|---|---|---|---|
| `POST /custom-webhooks/moderation/check` | Composer (logged-in) | session | Flow A sync text check; forwards to forums `text-check` |
| `POST /custom-webhooks/moderation/nudge-metric` | Composer (logged-in) | session | Records Edit / Post-anyway; forwards to forums `nudge-metrics` |
| `POST /custom-webhooks/moderation/callback` | **forums** | `X-Forums-Signature` (HMAC, `custom_webhooks_callback_secret`) | Receives the verdict; applies it |

### forums endpoints (inbound to forums)

| Route | Caller | Auth | Purpose |
|---|---|---|---|
| `POST /api/v1/discourse/moderation/text-check` | Discourse `check` | `X-Discourse-Event-Signature` (`webhook_secret`) | Real inline text verdict |
| `POST /api/v1/discourse/moderation/nudge-metrics` | Discourse `nudge_metric` | `X-Discourse-Event-Signature` | Analytics; writes `nudging_metrics` |
| SQS `discourse.moderation.sqs-queue` (prod) | API Gateway | HMAC on body | Async event intake |
| `POST /api/v1/discourse/moderation/dev-intake` (local only) | Discourse emit job | `X-Discourse-Signature` | Local HTTP shim for the SQS path |

> In **production** the async event goes Discourse → API Gateway → **SQS**;
> there is no production HTTP intake. Locally the plugin posts to `dev-intake`
> (enable with `discourse.moderation.dev-intake-enabled=true`), which runs the
> identical verify → dedup → dispatch path over HTTP.

### Signing (which secret signs which hop)

| Hop | Signer | Header | Secret |
|---|---|---|---|
| Discourse → forums (event / text-check / nudge-metrics) | Discourse | `custom_webhooks_signature_header` (default `X-Discourse-Signature`) | `custom_webhooks_secret` |
| forums → Discourse (verdict callback) | forums | `X-Forums-Signature` | `custom_webhooks_callback_secret` |

Both are `sha256=HMAC-SHA256(secret, rawBody)`, compared constant-time.

> **Header name must match on both sides.** Discourse sends the signature under
> the header named by `custom_webhooks_signature_header` (default
> `X-Discourse-Signature`); the forums examples use `X-Discourse-Event-Signature`.
> Whatever you configure on Discourse must be the header forums reads for that
> hop — set them to the same value.

---

## 3. Payloads

### 3.1 Event (Discourse → forums, Flows B & C)

Built by `DiscourseCustomWebhooks::PayloadBuilder`. Always carries `text`;
`images` is populated only when the post has image uploads and
`custom_webhooks_include_images` is on.

```json
{
  "event_id": "b7042bac-6aab-4fab-8933-9d1e01cabebe",
  "event": "post_created",
  "event_type": "topic",
  "post_id": 12345,
  "topic_id": 6789,
  "post_number": 1,
  "post_url": "https://forums.ea.com/t/my-topic/6789/1",
  "callback_url": "https://forums.ea.com/custom-webhooks/moderation/callback",
  "created_at": "2026-08-18T15:39:18Z",
  "updated_at": "2026-08-18T15:39:18Z",
  "category_id": 4,
  "actor": {
    "discourse_user_id": 2, "username": "alice", "display_name": "Alice",
    "sso_id": "1002920570207", "locale": "en", "trust_level": 1
  },
  "recipients": [],
  "text": { "title": "My topic title", "raw": "post markdown ..." },
  "images": [ { "url": "https://cdn/.../a.jpg?X-Amz-Signature=...", "secure": true, "sha1": "...", "filename": "a.jpg" } ],
  "has_images": true
}
```

- `event_type`: `topic` (first post), `reply`, or `pm`.
- `recipients`: populated only for private messages.
- `actor.sso_id`: from the `custom_webhooks_sso_provider` linked account.
- `callback_url`: the plugin's own callback route (forums prefers this over its configured default).

### 3.2 Verdict callback (forums → Discourse)

The plugin keys on `results.image.verdict` and/or `results.text`:

```json
{
  "event_id": "b7042bac-6aab-4fab-8933-9d1e01cabebe",
  "moderation_id": "5c897632-2b69-4627-b78c-5421ac5bbf9f",
  "post_id": 12345,
  "topic_id": 6789,
  "results": {
    "text":  { "violation_found": true, "can_publish": false, "category": "Abuse",
               "confidence": 0.99, "flagged_terms": ["idiots", "morons"],
               "reasoning": "Direct insults aimed at other users." },
    "image": { "verdict": "CLEAN", "status": "complete" }
  },
  "timestamp": 1787058599825
}
```

- Text violation ⇔ `results.text.violation_found == true` **or** `results.text.can_publish == false`.
- CSAM ⇔ `results.image.verdict == "CSAM"`.

### 3.3 Sync text-check response (forums → Discourse, Flow A)

The plugin normalises the forums response to exactly what the composer needs:

```json
{ "can_publish": false, "nudge_message": "...", "suggested_rewrite": null,
  "category": "Abuse", "event_id": "<uuid>" }
```

---

## 4. Scenarios — what to expect / what is done

| # | Scenario | Flow | forums result | What Discourse does | Post visible? | `/review` item? |
|---|---|---|---|---|---|---|
| 1 | Clean text | A | `can_publish:true` | Post is created normally | Yes | No |
| 2 | Abusive text, author picks **Edit** | A | `can_publish:false` | Save cancelled; composer stays open | Not created | No |
| 3 | Abusive text, author picks **Post anyway** | A→B | `can_publish:false`, then async `text.violation_found:true` | Post is created & published, then the async re-check **hides it** and raises a review item | Hidden from public (author/staff see it greyed) | **Yes** |
| 4 | Text engine unreachable | A | `200 {can_publish:true}` (fail-open) | Post allowed | Yes | No |
| 5 | Clean reply/edit (no image) | B | `text.violation_found:false` | No-op | Yes | No |
| 6 | Abusive reply/edit (no nudge shown) | B | `text.violation_found:true` | Post **hidden** + review item raised | Hidden from public (author/staff see it greyed) | **Yes** |
| 7 | Clean image post | C | `image.verdict:"CLEAN"` | Held post is published (unhidden) | Held → Yes | No |
| 8 | CSAM image in a public post | C | `image.verdict:"CSAM"` | Post destroyed + audited; T&S case filed | No (removed) | No (Khoros parity) |
| 9 | CSAM image in a PM | C | `image.verdict:"CSAM"` | Kept hidden + review (staff-scoped) | No | **Yes** |
| 10 | Image + abusive text together | B+C | `image` + `text` in one verdict | CSAM → destroy; otherwise a text violation hides the post; image-clean alone publishes | Hidden if any violation | If text violation |
| 11 | Duplicate event replayed | B/C | intake `409` / callback `noop` | Idempotent — nothing re-applied | unchanged | No |
| 12 | Bad signature (any hop) | any | `401` | Rejected, not retried | unchanged | No |
| 13 | Nudge response recorded | A | `202 {status:"recorded"}` | Row written to `nudging_metrics` | n/a | No |

> **Key behavioural note (scenarios 3 & 6):** a "Post anyway" / already-published
> text violation is **hidden from the public** and queued for a moderator. It is
> not silently removed — the author and staff still see the hidden post (greyed,
> with an "edit to make visible" notice), and a moderator restores or removes it
> from `/review`. Contrast with a CSAM public image (scenario 8), which is
> destroyed outright.

---

## 5. Moderator experience (`/review`)

Text violations (scenarios 3, 6) and CSAM-in-PM (9) appear in Discourse's native
`/review` queue as a **`ReviewableCustomWebhooksModeration`** item showing:

- category, subtype, severity, confidence, flagged terms, and the engine's reasoning;
- the post in context;
- native actions: **publish / keep hidden / delete / ignore**.

This is the direct analogue of the Khoros abuse queue. Text nudges alone
(scenario 2, Edit) never create a review item — exactly like Khoros.

---

## 6. Configuration

### Discourse (`Admin → Plugins → Custom webhooks`, `custom_webhooks_*`)

| Setting | Role in the loop |
|---|---|
| `custom_webhooks_enabled` | Master on/off |
| `custom_webhooks_payload_url` | Async event destination (SQS gateway / `dev-intake`) |
| `custom_webhooks_events` | Which events emit (`post_created`, `post_edited`, `topic_created`) |
| `custom_webhooks_check_text` | Enables Flow A nudge **and** Flow B async text re-check |
| `custom_webhooks_text_check_url` | forums `text-check` endpoint (Flow A). Blank disables the nudge |
| `custom_webhooks_include_images` | Send image links + enable Flow C |
| `custom_webhooks_hold_images_pending` | Hide image posts until a clean verdict (Flow C) |
| `custom_webhooks_nudge_metrics_url` | forums `nudge-metrics` endpoint. Blank skips analytics |
| `custom_webhooks_secret` | Signs Discourse → forums requests |
| `custom_webhooks_signature_header` | Header for the above (default `X-Discourse-Signature`) |
| `custom_webhooks_callback_secret` | Verifies the forums → Discourse callback |
| `custom_webhooks_sso_provider` | Authenticator whose linked account supplies `actor.sso_id` |
| `custom_webhooks_client_certificate` / `_client_key` / `_client_key_passphrase` / `_ca_certificate` / `_verify_ssl` | Optional mutual-TLS transport |

> Flow B fires whenever `custom_webhooks_check_text` is on — a text-only post now
> produces an async event too (previously async was image-only).

### forums (`discourse.moderation.*`)

| Property | Default | Purpose |
|---|---|---|
| `enabled` | `false` | Activates the SQS listener |
| `sqs-queue` | `discourse-moderation-queue` | Dedicated queue |
| `webhook-secret` | — | Verify inbound Discourse signature |
| `callback-secret` | — | Sign outbound verdict |
| `callback-url` | — | Default Discourse callback (per-event `callback_url` overrides) |
| `dedup-ttl-seconds` | `604800` | `event_id` dedup window |
| `dev-intake-enabled` | `false` | Local HTTP test intake |

---

## 7. Local testing

**forums** (from the `forums` repo):

```bash
./run-local.sh                          # boot forums locally (Azure OpenAI + CTD stub)
./trace.sh "you are an asshole"         # Flow A — prints the real text verdict
./trace.sh "thanks, lovely community"   # Flow A — clean
./trace.sh --image 40 "caption"         # Flow C — async event + callback
```

**Discourse** (from this repo, with the dev server + Sidekiq running):

```bash
# Flow B end to end: create a profane post, then confirm it is hidden AND queued
bin/rails runner '
  u = User.find_by(username: "<author>")
  p = PostCreator.create!(u, topic_id: <topic_id>, raw: "you are all idiots and morons")
  puts "post_id=#{p.id} hidden=#{p.hidden}"'         # hidden=false at creation
# after a few seconds (async re-check + callback):
bin/rails runner 'p = Post.find(<post_id>);
  puts "hidden=#{p.hidden} reviewables=#{Reviewable.where(target_id: p.id).count}"'
# expect: hidden=true  reviewables=1   → hidden from public + queued for /review

# plugin specs
LOAD_PLUGINS=1 bin/rspec plugins/discourse-custom-webhooks/spec/custom_webhooks_spec.rb
```

---

## 8. Naming note — `dev-intake`

`dev-intake` is a **test-only** HTTP shim for the SQS event path; production
intake is SQS, so there is no production HTTP intake to name. `/text-check`,
`/nudge-metrics`, and the callback **are** real production endpoints. If an HTTP
event intake is ever exposed in production, `POST /moderation/events` (mirroring
the API Gateway route) would be the appropriate name.
