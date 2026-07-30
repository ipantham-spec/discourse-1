# frozen_string_literal: true

class Vips::DominantColor
  def self.extract(path)
    Dir.mktmpdir("dominant-color") do |directory|
      thumbnail = File.join(directory, "thumbnail.v")
      profile = Rails.root.join("vendor/data/RT_sRGB.icm").to_s

      Vips.call(
        "thumbnail",
        path,
        thumbnail,
        "1",
        "--height",
        "1",
        "--size",
        "force",
        "--output-profile",
        profile,
        read: [path, profile],
        write: [directory],
        nice: 10,
        timeout: Upload::DOMINANT_COLOR_COMMAND_TIMEOUT_SECONDS,
      )

      output =
        Vips.call(
          "getpoint",
          thumbnail,
          "0",
          "0",
          read: [thumbnail],
          timeout: Upload::DOMINANT_COLOR_COMMAND_TIMEOUT_SECONDS,
          allow_untrusted: true,
        )
      components = output.split.map { |component| Float(component, exception: false) }
      if components.empty? || components.any?(&:nil?)
        raise "Calculated dominant color but unable to parse output:\n#{output}"
      end
      components = [components.first] * 3 if components.length < 3

      components
        .first(3)
        .map { |component| component.round.clamp(0, 255) }
        .map { |component| component.to_s(16).rjust(2, "0") }
        .join
        .upcase
    end
  end
end
