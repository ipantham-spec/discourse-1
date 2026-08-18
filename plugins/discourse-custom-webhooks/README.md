# discourse-custom-webhooks

A **custom webhooks plugin for the CSAM / ToSHUB content-moderation integration**.
It is like Discourse's built-in webhooks, but purpose-built for moderation: it
sends a **signed moderation event** to an external moderation pipeline when
selected forum events happen, and — unlike core webhooks — supports **mutual
TLS** (client-certificate authentication). Every transport input is configured
from the admin UI.

## Admin UI

`Admin → Plugins → Custom webhooks`

- **Overview** tab — what the moderation webhook does + a link to settings.
- **Settings** tab — every input (grouped in the `custom_webhooks` settings area).

## Settings (all admin-visible)

| Setting | Purpose |
|---|---|
| `custom_webhooks_enabled` | Master on/off. |
| `custom_webhooks_payload_url` | Destination moderation-pipeline endpoint. |
| `custom_webhooks_events` | Which events fire a delivery (`post_created`, `post_edited`, `topic_created`). |
| `custom_webhooks_sso_provider` | SSO authenticator name whose linked account holds the author's external identity (sent as `actor.sso_id`). |
| `custom_webhooks_include_images` | Include image-upload links for image/CSAM scanning. |
| `custom_webhooks_http_method` | `POST` or `PUT`. |
| `custom_webhooks_content_type` | Request `Content-Type`. |
| `custom_webhooks_request_timeout_seconds` | Per-request timeout (fail-open). |
| `custom_webhooks_secret` | HMAC-SHA256 signing secret. |
| `custom_webhooks_signature_header` | Header carrying `sha256=<hex>` (default `X-Discourse-Signature`). |
| `custom_webhooks_extra_headers` | Static headers (`Header-Name: value` per line). |
| `custom_webhooks_client_certificate` | mTLS client certificate (PEM). |
| `custom_webhooks_client_key` | mTLS private key (PEM). |
| `custom_webhooks_client_key_passphrase` | Passphrase for the private key. |
| `custom_webhooks_ca_certificate` | Extra CA(s) to trust (PEM). |
| `custom_webhooks_verify_ssl` | Verify the endpoint TLS certificate. |

## Delivery

On a subscribed event, the plugin enqueues `Jobs::CustomWebhooksEmitEvent`, which
builds the moderation payload (`DiscourseCustomWebhooks::PayloadBuilder`) and
sends it via `DiscourseCustomWebhooks::Emitter`. The emitter signs the raw body,
applies optional mTLS, and routes through `FinalDestination::FaradayAdapter`
(SSRF-safe). Delivery is **fail-open**: a transport error is logged, never
raised, so posting is never blocked.

### Moderation event payload

```json
{
  "event": "post_created",
  "event_type": "topic",
  "post_id": 123,
  "topic_id": 45,
  "post_number": 1,
  "post_url": "https://forum.example.com/t/.../45/1",
  "created_at": "2026-08-18T...Z",
  "category_id": 6,
  "actor": {
    "discourse_user_id": 2,
    "username": "alice",
    "display_name": "Alice",
    "sso_id": "1002920570207",
    "locale": "en",
    "trust_level": 1
  },
  "recipients": [],
  "text": { "title": "Topic title (first post only)", "raw": "post markdown" },
  "images": [
    { "url": "https://cdn/.../a.jpg", "secure": true, "sha1": "...", "filename": "a.jpg" }
  ],
  "has_images": true
}
```

- `event_type` is `topic` (first post), `reply`, or `pm`.
- `recipients` is populated only for private messages.
- `actor.sso_id` comes from the `custom_webhooks_sso_provider` linked account.

### Verifying the signature (receiver side)

```
signature = "sha256=" + HMAC_SHA256(custom_webhooks_secret, raw_request_body)
compare against the custom_webhooks_signature_header header (constant time)
```

## Relationship to the verdict callback

This plugin handles the **full moderation loop**:

- **Outbound** — signed moderation event to the pipeline (this plugin).
- **Inbound** — signed verdict callback that this plugin applies:
  `POST /custom-webhooks/moderation/callback` (verified with
  `custom_webhooks_callback_secret` via the `X-Forums-Signature` header).
  Clean → publish; text violation → keep hidden + `/review` item;
  CSAM public → destroy; CSAM in a PM → keep hidden + review. Idempotent on
  `event_id`.
- **Pre-publish nudge** — `POST /custom-webhooks/moderation/check` runs a
  synchronous text check from the composer; flagged text shows an
  Edit / Post-anyway dialog. Fails open.
- **Moderator dashboard** — violations appear in the native `/review` queue as a
  `ReviewableCustomWebhooksModeration` item with a details panel (category,
  subtype, severity, confidence, flagged terms, reasoning) and
  keep-hidden / publish / delete / ignore actions.

## Tests

```bash
LOAD_PLUGINS=1 bin/rspec plugins/discourse-custom-webhooks/spec/custom_webhooks_spec.rb
```
