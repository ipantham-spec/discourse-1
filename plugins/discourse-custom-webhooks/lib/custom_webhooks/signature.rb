# frozen_string_literal: true

module ::DiscourseCustomWebhooks
  # HMAC-SHA256 signing of the raw request body, formatted as "sha256=<hex>".
  # Shared by the emitter (to sign outbound requests) and by tests.
  module Signature
    PREFIX = "sha256"

    def self.sign(body, secret)
      "#{PREFIX}=#{OpenSSL::HMAC.hexdigest("sha256", secret.to_s, body.to_s)}"
    end

    # Constant-time comparison, provided for completeness/testing.
    def self.valid?(body, secret, provided)
      return false if secret.blank? || provided.blank?
      ActiveSupport::SecurityUtils.secure_compare(sign(body, secret), provided.to_s)
    end
  end
end
