# frozen_string_literal: true

RSpec.describe Vips do
  describe ".call" do
    it "processes an image with the stock CLI" do
      Dir.mktmpdir("vips-spec") do |directory|
        input = file_from_fixtures("logo.png").path
        output = File.join(directory, "copy.png")

        described_class.call("copy", input, output, read: [input], write: [directory])

        expect(FastImage.size(output)).to eq(FastImage.size(input))
      end
    end

    it "allows untrusted loaders only when explicitly requested" do
      Dir.mktmpdir("vips-spec") do |directory|
        input = File.join(directory, "input.svg")
        output = File.join(directory, "output.png")
        File.write(
          input,
          '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"><rect width="2" height="3" fill="red"/></svg>',
        )

        expect {
          described_class.call("copy", input, output, read: [input], write: [directory])
        }.to raise_error(Discourse::Utils::CommandError)

        described_class.call(
          "copy",
          input,
          output,
          read: [input],
          write: [directory],
          allow_untrusted: true,
        )

        expect(FastImage.size(output)).to eq([2, 3])
      end
    end
  end

  describe ".header" do
    it "reads an image header field" do
      input = file_from_fixtures("logo.png").path

      format = described_class.header(input, field: "format", read: [input])

      expect(format).to include("VIPS_FORMAT_UCHAR")
    end
  end

  describe ".dominant_color" do
    it "returns the image color as uppercase RGB hex" do
      input = file_from_fixtures("logo.png").path

      color = described_class.dominant_color(input)

      expect(color).to eq("514C3F")
    end
  end
end
