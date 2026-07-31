import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-ea-identity";

// Explicit labels for the EA settings page. Discourse humanizes setting keys
// automatically, which renders "Ea …" (the acronym list has no "ea") and cannot
// distinguish the SSO-endpoint certificate from the identity-endpoint
// certificate. These override the visible titles with EA casing and names that
// spell out which credential belongs to which endpoint.
const EA_SETTING_LABELS = {
  ea_identity_enabled: "EA authentication",
  ea_identity_button_title: "EA sign-in button title",

  // User SSO endpoints (Call 1 authorize + Call 2 token exchange)
  ea_identity_client_id: "EA SSO client ID",
  ea_identity_authorize_url: "EA SSO authorize URL",
  ea_identity_token_url: "EA SSO token URL",
  ea_identity_token_auth_method: "EA SSO token auth method",
  ea_identity_client_secret: "EA SSO client secret",

  // Token-endpoint mutual TLS (authenticates Discourse at the SSO token URL)
  ea_identity_auth_client_certificate: "EA SSO cert (token mTLS)",
  ea_identity_auth_client_key: "EA SSO key (token mTLS)",
  ea_identity_auth_client_key_passphrase: "EA SSO key passphrase (token mTLS)",

  // Identity/profile endpoint mutual TLS (Call 3)
  ea_identity_user_json_url: "EA identity (profile) URL",
  ea_identity_client_certificate: "EA identity cert (mTLS)",
  ea_identity_client_key: "EA identity key (mTLS)",
  ea_identity_client_key_passphrase: "EA identity key passphrase (mTLS)",

  // Service (client_credentials) token for the identity call's bearer header
  ea_identity_service_token_url: "EA service token URL (Orion)",
  ea_identity_service_client_id: "EA service client ID (Orion)",
  ea_identity_service_client_secret: "EA service client secret (Orion)",
  ea_identity_service_scope: "EA service token scope",
};

export default {
  name: "ea-identity-admin-plugin-configuration-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.setAdminPluginIcon(PLUGIN_ID, "key");

      api.modifyClass(
        "model:site-setting",
        (Superclass) =>
          class extends Superclass {
            get label() {
              const custom = EA_SETTING_LABELS[this.setting];
              if (custom) {
                return custom;
              }

              // Fall back to the humanized name, but fix the "Ea " casing for
              // any EA setting not explicitly mapped above.
              const base = this.humanized_name;
              if (
                typeof this.setting === "string" &&
                this.setting.startsWith("ea_identity") &&
                typeof base === "string"
              ) {
                return base.replace(/^Ea /, "EA ");
              }

              return base;
            }
          },
        { pluginId: PLUGIN_ID }
      );
    });
  },
};
