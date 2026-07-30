# frozen_string_literal: true

class OmniAuth::Strategies::EaIdentity < ::OmniAuth::Strategies::OAuth2
  option :name, "ea_identity"

  uid do
    if (path = SiteSetting.ea_identity_callback_user_id_path).present?
      recurse(access_token, [*path.split(".")])
    end
  end

  # The identity and email are resolved server-side in the authenticator
  # (either from the id_token or from the identity endpoint), so we only
  # need to surface the raw credentials here.
  credentials do
    hash = { "token" => access_token.token }
    hash["refresh_token"] = access_token.refresh_token if access_token.refresh_token
    hash["expires_at"] = access_token.expires_at if access_token.expires?
    hash["expires"] = access_token.expires?
    if (id_token = access_token.params["id_token"]).present?
      hash["id_token"] = id_token
    end
    hash
  end

  def callback_phase
    super
  rescue Faraday::Error => e
    detail =
      if e.is_a?(Faraday::TimeoutError)
        "timed out after #{GlobalSetting.ea_identity_request_timeout_seconds}s"
      else
        "failed"
      end
    Rails.logger.warn("EA Identity: token request #{detail}: #{e.class} #{e.message}")
    fail!(:ea_identity_request_failed, e)
  end

  def callback_url
    Discourse.base_url_no_prefix + script_name + callback_path
  end

  def recurse(obj, keys)
    return nil if !obj
    k = keys.shift
    result = obj.respond_to?(k) ? obj.send(k) : obj[k]
    keys.empty? ? result : recurse(result, keys)
  end
end
