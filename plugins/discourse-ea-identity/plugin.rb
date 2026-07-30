# frozen_string_literal: true

# name: discourse-ea-identity
# about: Authenticates users against the EA Identity service using an OAuth2 authorization-code flow with mutual TLS and a custom identity endpoint.
# version: 0.1
# authors: Discourse
# url: https://github.com/discourse/discourse/tree/main/plugins/discourse-ea-identity

enabled_site_setting :ea_identity_enabled

require_relative "lib/omniauth/strategies/ea_identity"
require_relative "lib/ea_identity_faraday_formatter"
require_relative "lib/ea_identity_authenticator"

GlobalSetting.add_default :ea_identity_request_timeout_seconds, 10

auth_provider title_setting: "ea_identity_button_title", authenticator: EaIdentityAuthenticator.new
