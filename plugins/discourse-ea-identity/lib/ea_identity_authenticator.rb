# frozen_string_literal: true

require "jwt"
require "tmpdir"
require "fileutils"

class EaIdentityAuthenticator < Auth::ManagedAuthenticator
  # The provider name drives the login button link, the OAuth callback path
  # (/auth/<name>/callback), and the find_authenticator lookup. We reuse the
  # "oidc" provider name so EA can keep the /auth/oidc/callback redirect URI it
  # already trusts. The bundled discourse-openid-connect plugin must stay
  # disabled to avoid a provider-name clash.
  def name
    "oidc"
  end

  def enabled?
    SiteSetting.ea_identity_enabled
  end

  def can_revoke?
    SiteSetting.ea_identity_allow_association_change
  end

  def can_connect_existing_user?
    SiteSetting.ea_identity_allow_association_change
  end

  def provides_groups?
    SiteSetting.ea_identity_json_groups_path.present?
  end

  def request_timeout_seconds
    GlobalSetting.ea_identity_request_timeout_seconds
  end

  def register_middleware(omniauth)
    omniauth.provider :ea_identity,
                      name: name,
                      setup:
                        lambda { |env|
                          opts = env["omniauth.strategy"].options
                          opts[:client_id] = SiteSetting.ea_identity_client_id
                          opts[:client_options] = {
                            authorize_url: SiteSetting.ea_identity_authorize_url,
                            token_url: token_endpoint_url,
                            token_method: SiteSetting.ea_identity_token_url_method.downcase.to_sym,
                            connection_opts: {
                              request: {
                                timeout: request_timeout_seconds,
                              },
                            },
                          }
                          opts[:authorize_options] = SiteSetting
                            .ea_identity_authorize_options
                            .split("|")
                            .map(&:to_sym)

                          # RFC 8705 tls_client_auth: authenticate to the token
                          # endpoint with a client certificate. The oauth2
                          # :tls_client_auth scheme sends only client_id (no
                          # client_secret), and we present the auth certificate
                          # on the TLS connection.
                          opts[:client_options][:connection_opts][:ssl] = token_ssl_options
                          opts[:client_options][:auth_scheme] = :tls_client_auth

                          if SiteSetting.ea_identity_scope.present?
                            opts[:scope] = SiteSetting.ea_identity_scope
                          end

                          extra_authorize = parse_authorize_params
                          opts[:authorize_params] = extra_authorize if extra_authorize.present?

                          opts[:pkce] = SiteSetting.ea_identity_use_pkce

                          opts[:client_options][:connection_build] = lambda do |builder|
                            if SiteSetting.ea_identity_debug_auth &&
                                 defined?(EaIdentityFaradayFormatter)
                              builder.response :logger,
                                               Rails.logger,
                                               {
                                                 bodies: true,
                                                 formatter: EaIdentityFaradayFormatter,
                                               }
                            end

                            builder.request :url_encoded
                            builder.adapter FinalDestination::FaradayAdapter
                          end
                        }
  end

  # Extra static query parameters appended to the authorization request (Call 1),
  # e.g. EA's release_type, display, hide_create or prompt. Configured as a
  # pipe-delimited list of key=value pairs: "release_type=123|display=junoWeb/login".
  def parse_authorize_params
    raw = SiteSetting.ea_identity_authorize_params.to_s
    raw
      .split("|")
      .each_with_object({}) do |pair, hash|
        key, _, value = pair.partition("=")
        key = key.strip
        next if key.blank?
        hash[key] = value.strip
      end
  end

  # EA exposes a separate server-to-server host for mutual-TLS client
  # authentication at the token endpoint. When the configured token URL still
  # points at the browser-facing host, transparently route to the mTLS host so
  # the client certificate is actually requested.
  def token_endpoint_url
    SiteSetting.ea_identity_token_url.sub("://accounts.int.ea.com/", "://accounts2s.int.ea.com/")
  end

  # Shared builder: Faraday client-certificate SSL options from PEM strings.
  # A certificate PEM may hold a leaf followed by intermediate certificates.
  def client_ssl_options(certificate, key, passphrase)
    return {} if certificate.blank?

    opts = {}
    certs = parse_certificates(certificate)
    opts[:client_cert] = (certs.length == 1 ? certs.first : certs) if certs.present?
    opts[:client_key] = OpenSSL::PKey.read(key, passphrase.presence) if key.present?
    opts
  rescue OpenSSL::OpenSSLError => e
    log("failed to build client SSL options: #{e.class} #{e.message}")
    raise
  end

  # Mutual-TLS options for the identity endpoint call (Call 3): client
  # certificate plus an optional extra CA and the TLS verification flag.
  def ssl_options
    opts =
      client_ssl_options(
        SiteSetting.ea_identity_client_certificate,
        SiteSetting.ea_identity_client_key,
        SiteSetting.ea_identity_client_key_passphrase,
      )

    if SiteSetting.ea_identity_ca_certificate.present?
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      parse_certificates(SiteSetting.ea_identity_ca_certificate).each { |c| store.add_cert(c) }
      opts[:cert_store] = store
    end

    opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless SiteSetting.ea_identity_verify_ssl

    opts
  end

  # Client-certificate options used to authenticate the token endpoint (Call 2)
  # when the certificate auth method is selected. Kept separate from the
  # identity endpoint's mutual TLS material.
  def token_ssl_options
    client_ssl_options(
      SiteSetting.ea_identity_auth_client_certificate,
      SiteSetting.ea_identity_auth_client_key,
      SiteSetting.ea_identity_auth_client_key_passphrase,
    )
  end

  # A PEM blob may contain a leaf certificate followed by intermediates.
  def parse_certificates(pem)
    return [] if pem.blank?
    pem
      .scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
      .map { |block| OpenSSL::X509::Certificate.new(block) }
  end

  # Surfaces an expired / not-yet-valid client certificate as a clear warning
  # instead of only a cryptic "SSL_read: certificate expired" TLS alert. The
  # leaf is the first certificate in the PEM; intermediates that follow are the
  # chain and are not the client identity.
  def warn_if_client_cert_invalid(pem)
    leaf = parse_certificates(pem).first
    return if leaf.nil?

    now = Time.now
    cn = leaf.subject.to_a.find { |name| name[0] == "CN" }&.dig(1)
    if leaf.not_after < now
      Rails.logger.warn(
        "EA Identity: identity client certificate CN=#{cn} EXPIRED on #{leaf.not_after} — renew it; EA will reject the mutual-TLS handshake.",
      )
    elsif leaf.not_before > now
      Rails.logger.warn(
        "EA Identity: identity client certificate CN=#{cn} is not valid until #{leaf.not_before}.",
      )
    end
  rescue OpenSSL::OpenSSLError => e
    log("could not inspect client certificate validity: #{e.class} #{e.message}")
  end

  def after_authenticate(auth, existing_account: nil)
    log <<~LOG
      after_authenticate response:

      uid: #{auth["uid"]}

      info:
      #{auth["info"].to_hash.to_yaml}
    LOG

    fetched_user_details = nil

    claims = SiteSetting.ea_identity_use_id_token ? decode_id_token(auth) : nil

    if claims
      apply_id_token_claims(auth, claims)
    elsif SiteSetting.ea_identity_fetch_user_details? &&
          SiteSetting.ea_identity_user_json_url.present?
      fetched_user_details = fetch_user_details(auth["credentials"]["token"], auth["uid"])

      if fetched_user_details
        if fetched_user_details[:_failure_reason]
          result = Auth::Result.new
          result.failed = true
          result.failed_reason = fetched_user_details[:_failure_reason]
          return result
        end

        auth["uid"] = fetched_user_details[:user_id] if fetched_user_details[:user_id]
        if fetched_user_details[:username]
          auth["info"]["nickname"] = fetched_user_details[:username]
        end
        auth["info"]["image"] = fetched_user_details[:avatar] if fetched_user_details[:avatar]
        %w[name email email_verified].each do |property|
          if fetched_user_details[property.to_sym]
            auth["info"][property] = fetched_user_details[property.to_sym]
          end
        end
      else
        result = Auth::Result.new
        result.failed = true
        result.failed_reason = I18n.t("login.authenticator_error_fetch_user_details")
        return result
      end
    end

    result = super(auth, existing_account: existing_account)

    if fetched_user_details && provides_groups?
      group_names = fetched_user_details[:groups] || []

      if SiteSetting.ea_identity_auto_create_groups
        # Create a basic Discourse group for each EA role (when missing) and add
        # the user to it. Membership is additive: roles that disappear are not
        # removed here. New accounts have no user yet, so the role list is
        # stashed on extra_data and applied in after_create_account.
        sync_ea_groups(result.user, group_names) if result.user
        result.extra_data = (result.extra_data || {}).merge(ea_groups: group_names)
      else
        result.associated_groups = group_names.map { |g| { id: g, name: g } }
      end
    end

    result
  end

  def after_create_account(user, auth_result)
    result = super

    if SiteSetting.ea_identity_auto_create_groups
      extra = auth_result[:extra_data] || {}
      group_names = extra[:ea_groups] || extra["ea_groups"]
      sync_ea_groups(user, group_names) if group_names.present?
    end

    result
  end

  def fetch_user_details(token, id)
    url = SiteSetting.ea_identity_user_json_url.sub(":token", token.to_s).sub(":id", id.to_s)
    method = SiteSetting.ea_identity_user_json_url_method.downcase.to_sym

    connection =
      Faraday.new(request: { timeout: request_timeout_seconds }, ssl: ssl_options) do |f|
        if SiteSetting.ea_identity_debug_auth && defined?(EaIdentityFaradayFormatter)
          f.response :logger, Rails.logger, { bodies: true, formatter: EaIdentityFaradayFormatter }
        end
        f.adapter FinalDestination::FaradayAdapter
      end

    headers = { "Accept" => "application/json" }.merge(auth_header(token))

    log("identity request: #{method.upcase} #{url}")
    log_identity_curl(method, url, headers)
    warn_if_client_cert_invalid(SiteSetting.ea_identity_client_certificate)

    begin
      response = connection.run_request(method, url, nil, headers)
    rescue Faraday::Error => e
      failure_detail =
        (
          if e.is_a?(Faraday::TimeoutError)
            "timed out after #{request_timeout_seconds}s"
          else
            "failed"
          end
        )
      Rails.logger.warn(
        "EA Identity: identity request to #{url} #{failure_detail}: #{e.class} #{e.message}",
      )
      return nil
    end

    log("identity response: #{response.status}\n\n#{response.body}")

    non_success_result = non_success_identity_result(response)
    return non_success_result if non_success_result

    return nil unless response.status == 200

    user_json = JSON.parse(response.body)
    return {} if user_json.blank?

    result = {}
    json_walk(result, user_json, :user_id)
    json_walk(result, user_json, :username)
    json_walk(result, user_json, :name)
    json_walk(result, user_json, :email)
    json_walk(result, user_json, :email_verified)
    json_walk(result, user_json, :avatar)
    result[:groups] = groups_from(user_json) if provides_groups?
    result
  rescue JSON::ParserError => e
    Rails.logger.warn("EA Identity: could not parse identity response: #{e.message}")
    nil
  end

  def non_success_identity_result(response)
    return nil if response.status == 200

    message = extract_identity_error_message(response.body)
    failure_reason = identity_failure_reason(response.status, message)
    return nil unless failure_reason

    if SiteSetting.ea_identity_fail_open_on_policy_errors
      Rails.logger.warn(
        "EA Identity: allowing login despite identity policy response status=#{response.status} message=#{message.inspect}",
      )
      return {}
    end

    Rails.logger.warn(
      "EA Identity: blocking login due to identity policy response status=#{response.status} message=#{message.inspect}",
    )

    { _failure_reason: failure_reason }
  end

  def extract_identity_error_message(raw_body)
    json = JSON.parse(raw_body)
    json.dig("error", "errorMessage") || json.dig("error", "message") || json["message"]
  rescue JSON::ParserError
    nil
  end

  def identity_failure_reason(status, message)
    normalized = message.to_s.upcase
    if normalized.include?("MINOR USERS FROM RESTRICTED COUNTRIES")
      return I18n.t("login.ea_identity_minor_user_restricted")
    end

    if normalized.include?("IP GEO FIELDS ARE NOT CONFIGURED")
      return I18n.t("login.ea_identity_ip_geo_not_configured")
    end

    I18n.t("login.ea_identity_policy_denied") if [403, 404].include?(status)
  end

  # The EA identity endpoint expects the end-user token in a custom header
  # (default X-ACCESS-TOKEN), and separately authenticates the calling service
  # through a standard Authorization: Bearer header (RFC 6750). The token passed
  # here is the user's SSO access token; the bearer value is a service
  # (client_credentials) token when one is configured, otherwise it falls back
  # to the same user token.
  def auth_header(token)
    header_name = SiteSetting.ea_identity_user_json_auth_header.presence || "X-ACCESS-TOKEN"
    scheme = SiteSetting.ea_identity_user_json_auth_header_scheme.presence
    value = scheme ? "#{scheme} #{token}" : token.to_s
    headers = { header_name => value }

    if header_name.casecmp("authorization") != 0
      if service_authorization_configured?
        service_token = service_access_token
        headers["Authorization"] = "Bearer #{service_token}" if service_token.present?
      elsif SiteSetting.ea_identity_send_bearer_authorization
        headers["Authorization"] = "Bearer #{token}"
      end
    end

    headers
  end

  def service_authorization_configured?
    SiteSetting.ea_identity_service_token_url.present? &&
      SiteSetting.ea_identity_service_client_id.present?
  end

  # Fetches (and caches) a service token via the OAuth2 client_credentials grant
  # from the separate service identity provider, used for the identity call's
  # Authorization: Bearer header. Cached until shortly before it expires.
  def service_access_token
    return nil unless service_authorization_configured?

    cache_key =
      "ea_identity_service_token:#{Digest::SHA1.hexdigest("#{SiteSetting.ea_identity_service_token_url}|#{SiteSetting.ea_identity_service_client_id}")}"
    cached = Discourse.redis.get(cache_key)
    return cached if cached.present?

    token, ttl = request_service_token
    Discourse.redis.setex(cache_key, [ttl.to_i - 60, 30].max, token) if token.present?
    token
  end

  def request_service_token
    url = SiteSetting.ea_identity_service_token_url
    body = {
      "grant_type" => "client_credentials",
      "client_id" => SiteSetting.ea_identity_service_client_id,
      "client_secret" => SiteSetting.ea_identity_service_client_secret,
    }
    if SiteSetting.ea_identity_service_scope.present?
      body["scope"] = SiteSetting.ea_identity_service_scope
    end

    connection =
      Faraday.new(request: { timeout: request_timeout_seconds }) do |f|
        f.request :url_encoded
        if SiteSetting.ea_identity_debug_auth && defined?(EaIdentityFaradayFormatter)
          f.response :logger, Rails.logger, { bodies: true, formatter: EaIdentityFaradayFormatter }
        end
        f.adapter FinalDestination::FaradayAdapter
      end

    log("service token request: POST #{url}")

    response = connection.post(url, body, { "Accept" => "application/json" })

    log("service token response: #{response.status}")

    unless response.status == 200
      Rails.logger.warn(
        "EA Identity: service token request to #{url} failed: #{response.status}\n#{response.body}",
      )
      return nil, 0
    end

    json = JSON.parse(response.body)
    [json["access_token"], (json["expires_in"] || 300).to_i]
  rescue Faraday::Error => e
    Rails.logger.warn("EA Identity: service token request errored: #{e.class} #{e.message}")
    [nil, 0]
  rescue JSON::ParserError => e
    Rails.logger.warn("EA Identity: could not parse service token response: #{e.message}")
    [nil, 0]
  end

  # Emits a copy-pasteable curl command equivalent to the identity request, so
  # the mutual-TLS call (which is server-to-server and never hits the browser)
  # can be reproduced by hand. Debug-only. The mTLS certificate and key are
  # written to mode-0600 temp files so --cert/--key can reference them; the
  # access token is included verbatim so the command actually works.
  def log_identity_curl(method, url, headers)
    return unless SiteSetting.ea_identity_debug_auth

    parts = ["curl -sS -X #{method.to_s.upcase}"]
    headers.each { |k, v| parts << "-H '#{k}: #{v}'" }

    if SiteSetting.ea_identity_client_certificate.present?
      dir = File.join(Dir.tmpdir, "ea_identity_debug")
      FileUtils.mkdir_p(dir)
      cert_path = File.join(dir, "identity_cert.pem")
      key_path = File.join(dir, "identity_key.pem")
      File.write(cert_path, SiteSetting.ea_identity_client_certificate)
      File.chmod(0o600, cert_path)
      parts << "--cert #{cert_path}"

      if SiteSetting.ea_identity_client_key.present?
        File.write(key_path, SiteSetting.ea_identity_client_key)
        File.chmod(0o600, key_path)
        parts << "--key #{key_path}"
        if SiteSetting.ea_identity_client_key_passphrase.present?
          parts << "--pass '#{SiteSetting.ea_identity_client_key_passphrase}'"
        end
      end
    end

    parts << "-k" unless SiteSetting.ea_identity_verify_ssl

    parts << "'#{url}'"

    log("identity request as curl:\n#{parts.join(" \\\n  ")}")
  rescue StandardError => e
    log("could not build identity curl: #{e.class} #{e.message}")
  end

  def decode_id_token(auth)
    id_token = auth.dig("credentials", "id_token")
    return nil if id_token.blank?

    # NOTE: The signature is intentionally not verified here. EA does not expose
    # a JWKS endpoint for this client, so trusting the claims is a deliberate
    # trade-off against making an extra identity call. Keep this path disabled
    # (ea_identity_use_id_token) unless the token source is fully trusted.
    JWT.decode(id_token, nil, false).first
  rescue JWT::DecodeError => e
    log("id_token could not be decoded, falling back to the identity endpoint: #{e.message}")
    nil
  end

  def apply_id_token_claims(auth, claims)
    user_id = claims[SiteSetting.ea_identity_id_token_user_id_claim] || claims["sub"]
    auth["uid"] = user_id if user_id.present?

    email = claims[SiteSetting.ea_identity_id_token_email_claim]
    auth["info"]["email"] = email if email.present?

    if (claim = SiteSetting.ea_identity_id_token_name_claim).present? && claims[claim].present?
      auth["info"]["name"] = claims[claim]
    end

    if (claim = SiteSetting.ea_identity_id_token_username_claim).present? && claims[claim].present?
      auth["info"]["nickname"] = claims[claim]
    end
  end

  # activeRoles is an array of objects (e.g. [{ "id" => "1", "name" => "admin" }]).
  # Discourse's group mapping expects a flat list of names, so extract the
  # configured property (name or id) from each role object.
  def groups_from(user_json)
    value =
      walk_path(user_json, parse_segments(expand_path(SiteSetting.ea_identity_json_groups_path)))

    unless value.is_a?(Array)
      log("groups path did not resolve to an array (got #{value.class})")
      return []
    end

    property = SiteSetting.ea_identity_groups_property
    value.map { |entry| entry.is_a?(Hash) ? entry[property] : entry }.compact.map(&:to_s)
  end

  # Additively ensure the user belongs to a basic Discourse group for each EA
  # role. Groups are created on first encounter and marked as EA-managed via a
  # custom field so admin-created groups are never mistaken for ours.
  def sync_ea_groups(user, raw_names)
    return if user.nil?

    Array(raw_names).each do |raw_name|
      group = find_or_create_ea_group(raw_name)
      next if group.nil?
      group.add(user) unless group.users.exists?(id: user.id)
    end
  rescue => e
    Rails.logger.warn(
      "EA Identity: group sync failed for user #{user&.id}: #{e.class} #{e.message}",
    )
  end

  def find_or_create_ea_group(raw_name)
    name = sanitize_group_name(raw_name)
    return nil if name.blank?

    group = Group.find_by("lower(name) = ?", name.downcase)
    if group
      # Never join or manage Discourse automatic/system groups (admins,
      # moderators, staff, trust_level_*) — a colliding role name must not
      # escalate privileges.
      return nil if group.automatic?
      return group
    end

    group =
      Group.create!(
        name: name,
        full_name: raw_name.to_s.strip.presence,
        visibility_level: Group.visibility_levels[:public],
        members_visibility_level: Group.visibility_levels[:public],
      )
    group.custom_fields["ea_identity_managed"] = "t"
    group.custom_fields["ea_identity_role"] = raw_name.to_s
    group.save_custom_fields
    group
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    Group.find_by("lower(name) = ?", name.downcase)
  end

  # EA role names may contain spaces or characters Discourse group names
  # disallow. Normalize to a valid group name (letters, digits, ._-) within the
  # username length cap.
  def sanitize_group_name(raw_name)
    name = raw_name.to_s.unicode_normalize.strip
    name = name.gsub(/\s+/, "_").gsub(/[^a-zA-Z0-9_.\-]/, "")
    name = name.gsub(/_+/, "_").gsub(/\A[_.\-]+|[_.\-]+\z/, "")
    max = SiteSetting.max_username_length
    name = name[0, max] if max && name.length > max
    name
  end

  def json_walk(result, user_json, prop)
    path = SiteSetting.public_send("ea_identity_json_#{prop}_path")
    return if path.blank?
    segments = parse_segments(expand_path(path))
    val = walk_path(user_json, segments)
    result[prop] = val.presence || (val == [] ? nil : val)
  end

  def expand_path(path)
    path.gsub(".[].", ".").gsub(".[", "[")
  end

  def walk_path(fragment, segments, seg_index = 0)
    first_seg = segments[seg_index]
    return if first_seg.blank? || fragment.blank?
    return nil unless fragment.is_a?(Hash) || fragment.is_a?(Array)
    first_seg =
      (
        if segments[seg_index].scan(/([\d+])/).length > 0
          first_seg.split("[")[0]
        else
          first_seg
        end
      )
    if fragment.is_a?(Hash)
      deref = fragment[first_seg]
    else
      array_index = 0
      if seg_index > 0
        last_index = segments[seg_index - 1].scan(/([\d+])/).flatten || [0]
        array_index = last_index.length > 0 ? last_index[0].to_i : 0
      end
      if fragment.any? && fragment.length >= array_index - 1
        deref = fragment[array_index][first_seg]
      else
        deref = nil
      end
    end

    if deref.blank? || seg_index == segments.size - 1
      deref
    else
      walk_path(deref, segments, seg_index + 1)
    end
  end

  def parse_segments(path)
    segments = [+""]
    quoted = false
    escaped = false

    path
      .split("")
      .each do |char|
        next_char_escaped = false
        if !escaped && (char == '"')
          quoted = !quoted
        elsif !escaped && !quoted && (char == ".")
          segments.append +""
        elsif !escaped && (char == '\\')
          next_char_escaped = true
        else
          segments.last << char
        end
        escaped = next_char_escaped
      end

    segments
  end

  def primary_email_verified?(auth)
    return true if SiteSetting.ea_identity_email_verified
    verified = auth["info"]["email_verified"]
    verified = true if verified == "true"
    verified = false if verified == "false"
    verified
  end

  def always_update_user_email?
    SiteSetting.ea_identity_overrides_email
  end

  def log(info)
    Rails.logger.warn("EA Identity Debugging: #{info}") if SiteSetting.ea_identity_debug_auth
  end
end
