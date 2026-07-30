# frozen_string_literal: true

describe EaIdentityAuthenticator do
  let(:authenticator) { described_class.new }

  let(:auth) do
    OmniAuth::AuthHash.new(
      "provider" => "ea_identity",
      "credentials" => {
        "token" => "the-access-token",
      },
      "uid" => "",
      "info" => {
      },
      "extra" => {
      },
    )
  end

  before do
    SiteSetting.ea_identity_enabled = true
    SiteSetting.ea_identity_user_json_url = "https://gateway.example.com/forums/identity"
    SiteSetting.ea_identity_email_verified = true
  end

  describe "#fetch_user_details" do
    it "sends the token in the configured custom header" do
      SiteSetting.ea_identity_json_user_id_path = "response.eaId"
      SiteSetting.ea_identity_json_email_path = "response.email"

      body = { response: { eaId: "12345", email: "player@example.com" } }.to_json
      stub =
        stub_request(:get, SiteSetting.ea_identity_user_json_url).with(
          headers: {
            "X-ACCESS-TOKEN" => "the-access-token",
          },
        ).to_return(status: 200, body: body)

      details = authenticator.fetch_user_details("the-access-token", nil)

      expect(stub).to have_been_requested
      expect(details[:user_id]).to eq("12345")
      expect(details[:email]).to eq("player@example.com")
    end

    it "supports an optional scheme prefix on the token header" do
      SiteSetting.ea_identity_user_json_auth_header = "Authorization"
      SiteSetting.ea_identity_user_json_auth_header_scheme = "Bearer"

      stub =
        stub_request(:get, SiteSetting.ea_identity_user_json_url).with(
          headers: {
            "Authorization" => "Bearer the-access-token",
          },
        ).to_return(status: 200, body: { response: { email: "player@example.com" } }.to_json)

      authenticator.fetch_user_details("the-access-token", nil)
      expect(stub).to have_been_requested
    end

    it "sends both X-ACCESS-TOKEN and Authorization: Bearer when enabled" do
      SiteSetting.ea_identity_send_bearer_authorization = true

      stub =
        stub_request(:get, SiteSetting.ea_identity_user_json_url).with(
          headers: {
            "X-ACCESS-TOKEN" => "the-access-token",
            "Authorization" => "Bearer the-access-token",
          },
        ).to_return(status: 200, body: { response: { email: "player@example.com" } }.to_json)

      authenticator.fetch_user_details("the-access-token", nil)
      expect(stub).to have_been_requested
    end

    it "does not duplicate Authorization when it is the primary header" do
      SiteSetting.ea_identity_user_json_auth_header = "Authorization"
      SiteSetting.ea_identity_user_json_auth_header_scheme = "Bearer"
      SiteSetting.ea_identity_send_bearer_authorization = true

      headers = authenticator.auth_header("the-access-token")
      expect(headers).to eq("Authorization" => "Bearer the-access-token")
    end

    it "maps unknown 403 policy responses to a generic denied reason" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 403,
        body: { error: { errorMessage: "Some policy rejection" } }.to_json,
      )

      result = authenticator.fetch_user_details("token", nil)

      expect(result).to eq(_failure_reason: I18n.t("login.ea_identity_policy_denied"))
    end

    it "maps minor-country restriction responses to a specific denied reason" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 403,
        body: {
          error: {
            errorMessage: "MINOR USERS FROM RESTRICTED COUNTRIES ARE NOT ALLOWED",
          },
        }.to_json,
      )

      result = authenticator.fetch_user_details("token", nil)

      expect(result).to eq(_failure_reason: I18n.t("login.ea_identity_minor_user_restricted"))
    end

    it "maps ipgeo-missing responses to a specific denied reason" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 404,
        body: { error: { errorMessage: "IP GEO FIELDS ARE NOT CONFIGURED FOR THE TOKEN" } }.to_json,
      )

      result = authenticator.fetch_user_details("token", nil)

      expect(result).to eq(_failure_reason: I18n.t("login.ea_identity_ip_geo_not_configured"))
    end

    it "allows login to continue on policy errors when fail-open is enabled" do
      SiteSetting.ea_identity_fail_open_on_policy_errors = true
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 403,
        body: { error: { errorMessage: "Some policy rejection" } }.to_json,
      )

      expect(authenticator.fetch_user_details("token", nil)).to eq({})
    end

    it "returns nil for non-policy upstream failures" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 500,
        body: "upstream exploded",
      )

      expect(authenticator.fetch_user_details("token", nil)).to be_nil
    end
  end

  describe "post-auth policy handling" do
    it "fails login with a specific reason when forums denies minor user access" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 403,
        body: {
          error: {
            errorMessage: "MINOR USERS FROM RESTRICTED COUNTRIES ARE NOT ALLOWED",
          },
        }.to_json,
      )

      result = authenticator.after_authenticate(auth)

      expect(result.failed).to eq(true)
      expect(result.failed_reason).to eq(I18n.t("login.ea_identity_minor_user_restricted"))
    end

    it "applies avatar URL from identity response during authentication" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 200,
        body: {
          response: {
            eaId: "12345",
            email: "player@example.com",
            avatar: "https://cdn.example.com/avatar.png",
          },
        }.to_json,
      )

      authenticator.after_authenticate(auth)

      expect(auth["info"]["image"]).to eq("https://cdn.example.com/avatar.png")
    end
  end

  describe "service (client_credentials) token for the Authorization header" do
    before do
      SiteSetting.ea_identity_service_token_url =
        "https://auth.example.com/realms/orion/protocol/openid-connect/token"
      SiteSetting.ea_identity_service_client_id = "forums-adapter"
      SiteSetting.ea_identity_service_client_secret = "sekret"
      Discourse.redis.keys("ea_identity_service_token:*").each { |k| Discourse.redis.del(k) }
    end

    it "mints a service token and uses it for Authorization while keeping the user token in X-ACCESS-TOKEN" do
      token_stub =
        stub_request(:post, SiteSetting.ea_identity_service_token_url).with(
          body: {
            "grant_type" => "client_credentials",
            "client_id" => "forums-adapter",
            "client_secret" => "sekret",
          },
        ).to_return(
          status: 200,
          body: { access_token: "the-service-token", expires_in: 3600 }.to_json,
        )

      identity_stub =
        stub_request(:get, SiteSetting.ea_identity_user_json_url).with(
          headers: {
            "X-ACCESS-TOKEN" => "the-access-token",
            "Authorization" => "Bearer the-service-token",
          },
        ).to_return(status: 200, body: { response: { email: "player@example.com" } }.to_json)

      authenticator.fetch_user_details("the-access-token", nil)

      expect(token_stub).to have_been_requested
      expect(identity_stub).to have_been_requested
    end

    it "caches the service token across calls" do
      token_stub =
        stub_request(:post, SiteSetting.ea_identity_service_token_url).to_return(
          status: 200,
          body: { access_token: "the-service-token", expires_in: 3600 }.to_json,
        )
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 200,
        body: { response: { email: "player@example.com" } }.to_json,
      )

      authenticator.fetch_user_details("the-access-token", nil)
      authenticator.fetch_user_details("the-access-token", nil)

      expect(token_stub).to have_been_requested.once
    end

    it "falls back to the user token for Authorization when the service token request fails" do
      stub_request(:post, SiteSetting.ea_identity_service_token_url).to_return(status: 401)

      identity_stub =
        stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
          status: 200,
          body: { response: { email: "player@example.com" } }.to_json,
        )

      authenticator.fetch_user_details("the-access-token", nil)

      expect(identity_stub).to have_been_requested
    end

    it "does not send an Authorization header at all when no service token and bearer disabled" do
      SiteSetting.ea_identity_service_token_url = ""
      SiteSetting.ea_identity_send_bearer_authorization = false

      headers = authenticator.auth_header("the-access-token")
      expect(headers).to eq("X-ACCESS-TOKEN" => "the-access-token")
    end
  end

  describe "role object group mapping" do
    before { SiteSetting.ea_identity_json_groups_path = "response.activeRoles" }

    let(:body) do
      {
        response: {
          email: "player@example.com",
          activeRoles: [{ id: "1", name: "moderators" }, { id: "2", name: "vip" }],
        },
      }.to_json
    end

    it "extracts the name property from each role object by default" do
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(status: 200, body: body)
      result = authenticator.after_authenticate(auth)
      expect(result.associated_groups).to eq(
        [{ id: "moderators", name: "moderators" }, { id: "vip", name: "vip" }],
      )
    end

    it "can extract the id property instead" do
      SiteSetting.ea_identity_groups_property = "id"
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(status: 200, body: body)
      result = authenticator.after_authenticate(auth)
      expect(result.associated_groups).to eq([{ id: "1", name: "1" }, { id: "2", name: "2" }])
    end

    it "returns an empty array when the path resolves to a non-array" do
      SiteSetting.ea_identity_json_groups_path = "response.email"
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(status: 200, body: body)
      result = authenticator.after_authenticate(auth)
      expect(result.associated_groups).to eq([])
    end
  end

  describe "id_token fast-path" do
    before do
      SiteSetting.ea_identity_use_id_token = true
      SiteSetting.ea_identity_id_token_user_id_claim = "eaId"
      SiteSetting.ea_identity_id_token_email_claim = "email"
    end

    it "reads details from the id_token and skips the identity call" do
      claims = { "eaId" => "999", "email" => "claims@example.com" }
      auth["credentials"]["id_token"] = JWT.encode(claims, nil, "none")

      authenticator.expects(:fetch_user_details).never
      result = authenticator.after_authenticate(auth)

      expect(result.extra_data[:uid]).to eq("999")
      expect(result.email).to eq("claims@example.com")
    end

    it "falls back to the identity endpoint when the id_token is missing" do
      SiteSetting.ea_identity_json_email_path = "response.email"
      stub_request(:get, SiteSetting.ea_identity_user_json_url).to_return(
        status: 200,
        body: { response: { email: "fallback@example.com" } }.to_json,
      )

      result = authenticator.after_authenticate(auth)
      expect(result.email).to eq("fallback@example.com")
    end
  end

  describe "#ssl_options" do
    it "returns an empty hash when no client certificate is configured" do
      SiteSetting.ea_identity_client_certificate = ""
      expect(authenticator.ssl_options).to eq({})
    end

    it "builds client cert and key options when a certificate is configured" do
      key = OpenSSL::PKey::RSA.new(2048)
      name = OpenSSL::X509::Name.parse("/CN=test")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = name
      cert.issuer = name
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))

      SiteSetting.ea_identity_client_certificate = cert.to_pem
      SiteSetting.ea_identity_client_key = key.to_pem

      opts = authenticator.ssl_options
      expect(opts[:client_cert]).to be_a(OpenSSL::X509::Certificate)
      expect(opts[:client_key]).to be_a(OpenSSL::PKey::RSA)
    end
  end

  describe "token endpoint authentication method" do
    def self_signed_pair
      key = OpenSSL::PKey::RSA.new(2048)
      name = OpenSSL::X509::Name.parse("/CN=token-auth")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = name
      cert.issuer = name
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      [cert, key]
    end

    it "defaults to client_secret" do
      expect(authenticator.token_auth_via_certificate?).to eq(false)
    end

    it "is certificate mode when selected" do
      SiteSetting.ea_identity_token_auth_method = "certificate"
      expect(authenticator.token_auth_via_certificate?).to eq(true)
    end

    it "uses the oauth2_basic provider name (callback) for client secret auth" do
      SiteSetting.ea_identity_token_auth_method = "client_secret"
      expect(authenticator.name).to eq("oauth2_basic")
    end

    it "uses the oidc provider name (callback) for certificate auth" do
      SiteSetting.ea_identity_token_auth_method = "certificate"
      expect(authenticator.name).to eq("oidc")
    end

    it "auto-routes the token endpoint to the mTLS host in certificate mode" do
      SiteSetting.ea_identity_token_auth_method = "certificate"
      SiteSetting.ea_identity_token_url = "https://accounts.int.ea.com/connect/token"
      expect(authenticator.token_endpoint_url).to eq("https://accounts2s.int.ea.com/connect/token")
    end

    it "leaves an already-mTLS token host unchanged in certificate mode" do
      SiteSetting.ea_identity_token_auth_method = "certificate"
      SiteSetting.ea_identity_token_url = "https://accounts2s.int.ea.com/connect/token"
      expect(authenticator.token_endpoint_url).to eq("https://accounts2s.int.ea.com/connect/token")
    end

    it "does not rewrite the token host for client secret auth" do
      SiteSetting.ea_identity_token_auth_method = "client_secret"
      SiteSetting.ea_identity_token_url = "https://accounts.int.ea.com/connect/token"
      expect(authenticator.token_endpoint_url).to eq("https://accounts.int.ea.com/connect/token")
    end

    it "builds token SSL options from the dedicated auth certificate" do
      cert, key = self_signed_pair
      SiteSetting.ea_identity_auth_client_certificate = cert.to_pem
      SiteSetting.ea_identity_auth_client_key = key.to_pem

      opts = authenticator.token_ssl_options
      expect(opts[:client_cert]).to be_a(OpenSSL::X509::Certificate)
      expect(opts[:client_key]).to be_a(OpenSSL::PKey::RSA)
    end

    it "keeps token auth material separate from the identity certificate" do
      cert, key = self_signed_pair
      SiteSetting.ea_identity_auth_client_certificate = cert.to_pem
      SiteSetting.ea_identity_auth_client_key = key.to_pem
      # No identity certificate configured.
      expect(authenticator.ssl_options).to eq({})
      expect(authenticator.token_ssl_options[:client_cert]).to be_a(OpenSSL::X509::Certificate)
    end
  end

  describe "#warn_if_client_cert_invalid" do
    def cert_with_validity(not_before, not_after)
      key = OpenSSL::PKey::RSA.new(2048)
      name = OpenSSL::X509::Name.parse("/CN=identity-client")
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = name
      cert.issuer = name
      cert.public_key = key.public_key
      cert.not_before = not_before
      cert.not_after = not_after
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      cert
    end

    it "warns when the client certificate is expired" do
      cert = cert_with_validity(Time.now - 7200, Time.now - 3600)
      Rails.logger.expects(:warn).with(regexp_matches(/EXPIRED/))
      authenticator.warn_if_client_cert_invalid(cert.to_pem)
    end

    it "does not warn for a currently-valid certificate" do
      cert = cert_with_validity(Time.now - 3600, Time.now + 3600)
      Rails.logger.expects(:warn).never
      authenticator.warn_if_client_cert_invalid(cert.to_pem)
    end

    it "is a no-op when no certificate is configured" do
      Rails.logger.expects(:warn).never
      authenticator.warn_if_client_cert_invalid("")
    end
  end

  describe "#parse_authorize_params" do
    it "parses a pipe-delimited key=value list" do
      SiteSetting.ea_identity_authorize_params =
        "release_type=1234|display=junoWeb/login|hide_create=true"
      expect(authenticator.parse_authorize_params).to eq(
        "release_type" => "1234",
        "display" => "junoWeb/login",
        "hide_create" => "true",
      )
    end

    it "returns an empty hash when unset" do
      SiteSetting.ea_identity_authorize_params = ""
      expect(authenticator.parse_authorize_params).to eq({})
    end

    it "ignores blank segments and trims whitespace" do
      SiteSetting.ea_identity_authorize_params = " release_type = 5 || display=x "
      expect(authenticator.parse_authorize_params).to eq("release_type" => "5", "display" => "x")
    end
  end
end
