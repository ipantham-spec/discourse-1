# frozen_string_literal: true

require "tmpdir"

module Vips
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

  def self.header(path, field:, read: [], timeout: nil, failure_message: "")
    run(
      "vipsheader",
      "--field",
      field,
      path,
      read: [path, *read],
      write: [],
      timeout:,
      allow_untrusted: false,
      failure_message:,
    )
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
end
