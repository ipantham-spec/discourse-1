## discourse-ea-identity

Authenticates Discourse users against the EA Identity service using an OAuth2
authorization-code flow. It is modeled on `discourse-oauth2-basic` but adds the
pieces the EA flow requires and that the basic plugin cannot express through
configuration alone:

- **Mutual-TLS token exchange.** The token exchange is authenticated with a
  client certificate (mutual-TLS client authentication, RFC 8705), independent
  of the identity endpoint's mutual TLS.
- **Mutual TLS (mTLS) for identity.** A separate client certificate, private key
  (with optional passphrase) and optional CA bundle are presented on the request
  to the EA identity endpoint.
- **Custom token header.** The identity endpoint expects the access token in a
  configurable header (`X-ACCESS-TOKEN` by default) instead of
  `Authorization: Bearer`.
- **Role objects.** Group syncing reads an array of role *objects*
  (`activeRoles: [{ id, name }]`) and extracts a configurable property
  (`name` or `id`) for each Discourse group.
- **Optional `id_token` fast-path.** When the token response contains an
  `id_token`, its claims can be used directly, skipping the identity call.

### The login flow

1. The user is redirected to `ea_identity_authorize_url` to sign in.
2. EA redirects back to the callback (`/auth/oidc/callback`) with a one-time code.
3. Discourse exchanges the code for an access token at `ea_identity_token_url`,
   authenticating with a client certificate (mutual TLS).
4. Discourse calls `ea_identity_user_json_url` with the access token in the
   `X-ACCESS-TOKEN` header (over mutual TLS) to fetch the profile — unless an
   `id_token` fast-path is enabled and available.

The plugin reuses the `oidc` provider name so EA can keep a redirect URI it
already trusts:

- `/auth/oidc/callback` (keep `discourse-openid-connect` disabled to avoid a
  provider-name clash)

Register that redirect URI with EA.

### Configuration

The plugin has its own **EA Login** page under **Admin → Plugins → EA Login**,
separate from the core Login config. It shows only the fields required to run
and test EA SSO:

| Setting | Purpose |
| --- | --- |
| `ea_identity_enabled` | Turn the provider on (enable this last) |
| `ea_identity_button_title` | Text on the login button |
| `ea_identity_client_id` | OAuth2 client ID |
| `ea_identity_authorize_url` | Authorization URL (step 1) |
| `ea_identity_token_url` | Token URL (step 3) |
| `ea_identity_user_json_url` | Identity endpoint (step 4) |
| `ea_identity_auth_client_certificate` / `ea_identity_auth_client_key` / `ea_identity_auth_client_key_passphrase` | Client certificate used for the token-endpoint mutual TLS |
| `ea_identity_client_certificate` / `ea_identity_client_key` / `ea_identity_client_key_passphrase` | Client certificate for the identity endpoint's mutual TLS |

The token endpoint and the identity endpoint use **separate** certificate
settings, so each call can present a different client certificate. Identity mTLS
activates automatically once its certificate is present.

Everything else (JSON paths, token header, HTTP methods, role/group mapping,
`id_token` fast-path, `ca_certificate`, `verify_ssl`, debug logging, …) is
pre-configured for the EA identity schema and hidden from the tab. Those
defaults can be changed from the rails console if a deployment ever needs to,
for example:

```ruby
SiteSetting.ea_identity_json_groups_path = "response.activeRoles"
SiteSetting.ea_identity_verify_ssl = false # local testing only
```
#### id_token fast-path

| Setting | Purpose |
| --- | --- |
| `ea_identity_use_id_token` | Read claims from the `id_token` and skip the identity call |
| `ea_identity_id_token_user_id_claim` | Claim holding the user id (falls back to `sub`) |
| `ea_identity_id_token_email_claim` | Claim holding the email |

> **Security note:** the `id_token` signature is **not** verified (EA does not
> expose a JWKS endpoint for this client). Only enable `ea_identity_use_id_token`
> when the token source is fully trusted; otherwise leave it off and rely on the
> identity endpoint.

### Running the tests

```
LOAD_PLUGINS=1 bin/rspec plugins/discourse-ea-identity/spec/plugin_spec.rb
```

### License

MIT
