# frozen_string_literal: true

require "faraday/logging/formatter"

class EaIdentityFaradayFormatter < Faraday::Logging::Formatter
  def request(env)
    warn <<~LOG
      EA Identity Debugging: request #{env.method.upcase} #{env.url}

      Headers:
      #{redact(env.request_headers).to_yaml}

      Body:
      #{env[:body].to_yaml}
    LOG
  end

  def response(env)
    warn <<~LOG
      EA Identity Debugging: response status #{env.status}

      From #{env.method.upcase} #{env.url}

      Headers:
      #{env.response_headers.to_yaml}

      Body:
      #{env[:body].to_yaml}
    LOG
  end

  private

  # Avoid writing raw access tokens / secrets to the logs even in debug mode.
  def redact(headers)
    headers.each_with_object({}) do |(key, value), hash|
      hash[key] = (
        if %w[authorization x-access-token].include?(key.to_s.downcase)
          "[redacted]"
        else
          value
        end
      )
    end
  end
end
