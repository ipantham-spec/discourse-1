# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Point ImageMagick at Discourse's security policy (config/imagemagick/policy.xml).
# Child processes inherit this env var, so it covers every identify/magick/convert
# call. Refuse to boot if it points somewhere else, since overriding it would
# bypass the policy. Our own value is allowed (the app may boot more than once in
# a process tree, e.g. parallel test workers).
source_dir = Rails.root.join("config/imagemagick").to_s

# On macOS the system temp directories (/tmp, /var/folders/...) are symlinks into
# /private, so the policy's `symlink rights=none follow` rule denies every read
# and write of a temp file and breaks all image processing. macOS is a
# local-development-only platform here (the Landlock sandbox that provides the
# real filesystem isolation is Linux-only), so derive a policy without that one
# rule on Darwin. Linux/production keeps the full hardened policy unchanged.
path =
  if RUBY_PLATFORM.include?("darwin")
    derived = File.join(Dir.tmpdir, "discourse-imagemagick-policy")
    FileUtils.mkdir_p(derived)
    policy = File.read(File.join(source_dir, "policy.xml"))
    File.write(File.join(derived, "policy.xml"), policy.gsub(/^.*name="symlink".*\n?/, ""))
    derived
  else
    source_dir
  end

if ENV["MAGICK_CONFIGURE_PATH"] && ENV["MAGICK_CONFIGURE_PATH"] != path
  raise "MAGICK_CONFIGURE_PATH must not be set externally; Discourse manages it " \
          "to enforce its ImageMagick security policy (config/imagemagick/policy.xml)."
end

ENV["MAGICK_CONFIGURE_PATH"] = path
