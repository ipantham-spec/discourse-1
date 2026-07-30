# frozen_string_literal: true

require "tmpdir"

class Vips
  DEFAULT_TIMEOUT = 30
  RLIMITS = {
    cpu_seconds: 300,
    memory_bytes: 4 * 1024 * 1024 * 1024,
    file_size_bytes: 10 * 1024 * 1024 * 1024,
    open_files: 1024,
  }.freeze

  def self.call(
    operation,
    *arguments,
    read: [],
    write: [],
    timeout: nil,
    nice: nil,
    allow_untrusted: false,
    failure_message: ""
  )
    command = ["vips", operation, *arguments]
    command = ["nice", "-n", nice.to_s, *command] if nice
    run(*command, read:, write:, timeout:, allow_untrusted:, failure_message:)
  end

  def self.header(path, field:, read: [], timeout: nil, allow_untrusted: false, failure_message: "")
    headers(path, fields: [field], read:, timeout:, allow_untrusted:, failure_message:).first
  end

  def self.headers(
    path,
    fields:,
    read: [],
    timeout: nil,
    allow_untrusted: false,
    failure_message: ""
  )
    run(
      "vipsheader",
      *fields.flat_map { |field| ["--field", field] },
      path,
      read: [path, *read],
      write: [],
      timeout:,
      allow_untrusted:,
      failure_message:,
    ).lines(chomp: true)
  end
  private_class_method :headers

  def self.dominant_color(path)
    Dir.mktmpdir("dominant-color") do |directory|
      thumbnail = File.join(directory, "thumbnail.v")
      profile = Rails.root.join("vendor/data/RT_sRGB.icm").to_s

      call(
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
        call(
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

  def self.run(*command, read:, write:, timeout:, allow_untrusted:, failure_message:)
    Dir.mktmpdir("discourse-vips-") do |scratch|
      environment = {
        **ENV.slice("PATH", "LANG", "LC_ALL"),
        "TMPDIR" => scratch,
        "HOME" => scratch,
        "XDG_CACHE_HOME" => scratch,
        "MALLOC_ARENA_MAX" => "2",
      }
      environment["VIPS_BLOCK_UNTRUSTED"] = "1" if !allow_untrusted

      Discourse::SafeExec.capture(
        *command,
        env: environment,
        unsetenv_others: true,
        read: [*Discourse::SafeExec.default_read_paths, *read],
        write: [scratch, *write],
        execute: Discourse::SafeExec.default_execute_paths,
        timeout: timeout || DEFAULT_TIMEOUT,
        rlimits: RLIMITS,
        failure_message:,
        seccomp_deny_network: true,
      )
    end
  end
  private_class_method :run
  private_constant :DEFAULT_TIMEOUT, :RLIMITS
end

require_relative "vips/ico"
require_relative "vips/png_metadata"
require_relative "vips/image_processor"
require_relative "vips/jpeg_quality"
