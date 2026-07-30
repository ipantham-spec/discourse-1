# frozen_string_literal: true

class ProblemCheck::Vips < ProblemCheck
  self.priority = "low"

  def call
    if Kernel.system("command -v vips >/dev/null && command -v vipsheader >/dev/null;")
      return no_problem
    end

    problem
  end
end
