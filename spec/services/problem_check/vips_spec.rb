# frozen_string_literal: true

RSpec.describe ProblemCheck::Vips do
  subject(:check) { described_class.new }

  describe "#call" do
    it "reports no problem when the required libvips tools are installed" do
      Kernel.stubs(system: true)

      expect(check).to be_chill_about_it
    end

    it "reports a problem when a required libvips tool is not installed" do
      Kernel.stubs(system: false)

      expect(check).to have_a_problem.with_priority("low").with_message(
        'The libvips command-line tools are not installed. Install libvips using your package manager or <a href="https://www.libvips.org/install.html" target="_blank">follow the libvips installation guide</a>.',
      )
    end
  end
end
