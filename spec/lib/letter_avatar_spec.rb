# frozen_string_literal: true

require "chunky_png"
require "letter_avatar"

RSpec.describe LetterAvatar do
  describe ".generate" do
    it "renders every configured avatar size" do
      ImageMagick.expects(:magick).never
      sizes = Discourse.avatar_sizes.to_a.sort

      dimensions =
        sizes.map do |size|
          path = described_class.generate("all-sizes", size, cache: true)
          FastImage.size(path)
        end

      expect(dimensions).to eq(sizes.map { |size| [size, size] })
    end

    it "renders representative scripts, combining characters, fallback glyphs, and XML text" do
      letters = ["A", "Ж", "ब", "한", "e\u0301", "🦄", "<&"]
      color = [61, 155, 243]

      rendered_glyphs =
        letters.map.with_index do |letter, index|
          identity = described_class::Identity.new
          identity.color = color
          identity.letter = letter
          path = described_class.generate("glyph-#{index}", 144, identity: identity, cache: false)
          image = ChunkyPNG::Image.from_file(path)
          image.pixels.uniq.length
        end

      expect(rendered_glyphs).to all(be > 1)
    end

    it "does not fall back to ImageMagick when vips fails" do
      described_class.stubs(vips_version: "failure")
      Vips.stubs(:call).raises(Discourse::Utils::CommandError.new("vips failed"))
      ImageMagick.expects(:magick).never

      expect { described_class.generate("failure", 120, cache: false) }.to raise_error(
        Discourse::Utils::CommandError,
        "vips failed",
      )
    end
  end

  describe ".cleanup_old" do
    it "removes stale cache versions" do
      path = described_class.cache_path

      FileUtils.mkdir_p(path + "junk")
      described_class.generate("test", 100)
      described_class.cleanup_old

      expect(Dir.entries(File.dirname(path)).length).to eq(3)
    end
  end

  describe ".cache_path" do
    it "changes when the vips implementation changes" do
      described_class.stubs(vips_version: "first")
      first_path = described_class.cache_path

      described_class.stubs(vips_version: "second")
      second_path = described_class.cache_path

      expect(first_path).to end_with("/6_first")
      expect(second_path).to end_with("/6_second")
    end
  end
end
