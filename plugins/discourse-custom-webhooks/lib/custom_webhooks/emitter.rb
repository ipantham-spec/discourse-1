# frozen_string_literal: true

module ::DiscourseCustomWebhooks
  # Signs and sends the webhook request to the configured endpoint. Supports
  # optional mutual TLS (client certificate authentication) and HMAC-SHA256
  # signing of the raw body. Delivery is fail-open: a transport error is logged
  # but never raised, so it cannot block the action that triggered the event.
  module Emitter
    module_function

    def enabled?
      SiteSetting.custom_webhooks_enabled && SiteSetting.custom_webhooks_payload_url.present?
    end

    # True when the given event name is in the admin-configured event list.
    def subscribed?(event)
      SiteSetting.custom_webhooks_events.to_s.split("|").include?(event.to_s)
    end

    # True when a post should produce a moderation event at all: regular posts by
    # a real user, when at least one check is enabled.
    def eligible?(post)
      return false if post.blank? || post.user_id.blank?
      return false unless post.post_type == Post.types[:regular]
      SiteSetting.custom_webhooks_check_text || SiteSetting.custom_webhooks_include_images
    end

    # True when the post references at least one image upload.
    def post_has_image?(post)
      post.uploads.to_a.any? do |upload|
        upload.original_filename.present? &&
          FileHelper.is_supported_image?(upload.original_filename)
      end
    rescue StandardError
      false
    end

    def deliver(payload_hash, ref: nil)
      return unless enabled?

      body = payload_hash.to_json
      url = SiteSetting.custom_webhooks_payload_url

      response =
        connection.run_request(http_method, url, body, request_headers(body)) do |req|
          # headers/body already set via run_request args
        end

      unless response.success?
        Rails.logger.warn(
          "Custom webhooks: delivery#{ref ? " for #{ref}" : ""} returned HTTP #{response.status}",
        )
      end

      response
    rescue Faraday::Error, OpenSSL::OpenSSLError => e
      # Fail open: a webhook failure must never block the triggering action.
      Rails.logger.warn(
        "Custom webhooks: delivery#{ref ? " for #{ref}" : ""} failed: #{e.class} #{e.message}",
      )
      nil
    end

    def http_method
      if SiteSetting.custom_webhooks_http_method.to_s.downcase == "put"
        :put
      else
        :post
      end
    end

    def request_headers(body)
      headers = {
        "Content-Type" => SiteSetting.custom_webhooks_content_type.presence || "application/json",
      }

      secret = SiteSetting.custom_webhooks_secret
      if secret.present?
        header = SiteSetting.custom_webhooks_signature_header.presence || "X-Discourse-Signature"
        headers[header] = Signature.sign(body, secret)
      end

      extra_headers.each { |k, v| headers[k] = v }
      headers
    end

    # Parses the admin "extra headers" list (each entry "Header-Name: value").
    def extra_headers
      SiteSetting
        .custom_webhooks_extra_headers
        .to_s
        .split("|")
        .filter_map do |line|
          key, value = line.split(":", 2)
          next if key.blank? || value.blank?
          [key.strip, value.strip]
        end
    end

    def connection
      Faraday.new(
        request: {
          timeout: SiteSetting.custom_webhooks_request_timeout_seconds,
        },
        ssl: ssl_options,
      ) { |f| f.adapter FinalDestination::FaradayAdapter }
    end

    # Mutual-TLS options: client certificate/key (+ passphrase), an optional
    # extra CA, and the TLS verification flag.
    def ssl_options
      opts = {}

      certificate = SiteSetting.custom_webhooks_client_certificate
      if certificate.present?
        certs = parse_certificates(certificate)
        opts[:client_cert] = (
          if certs.length == 1
            certs.first
          else
            certs
          end
        ) if certs.present?

        key = SiteSetting.custom_webhooks_client_key
        if key.present?
          opts[:client_key] = OpenSSL::PKey.read(
            key,
            SiteSetting.custom_webhooks_client_key_passphrase.presence,
          )
        end
      end

      if SiteSetting.custom_webhooks_ca_certificate.present?
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        parse_certificates(SiteSetting.custom_webhooks_ca_certificate).each do |c|
          store.add_cert(c)
        end
        opts[:cert_store] = store
      end

      opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless SiteSetting.custom_webhooks_verify_ssl
      opts
    end

    # A PEM blob may contain a leaf certificate followed by intermediates.
    def parse_certificates(pem)
      return [] if pem.blank?
      pem
        .scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
        .map { |block| OpenSSL::X509::Certificate.new(block) }
    end
  end
end
