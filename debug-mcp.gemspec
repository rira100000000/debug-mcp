# frozen_string_literal: true

require_relative "lib/debug_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "debug-mcp"
  spec.version = DebugMcp::VERSION
  spec.authors = ["rira100000000"]
  spec.email = ["101010hayakawa@gmail.com"]

  spec.summary = "MCP server for Ruby runtime debugging"
  spec.description = "An MCP (Model Context Protocol) server that provides LLM agents with access to " \
                     "runtime context of executing Ruby processes. Connect to debug sessions, " \
                     "evaluate code, inspect objects, and control execution flow via MCP tools."
  spec.homepage = "https://github.com/rira100000000/debug-mcp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  gemspec_file = File.expand_path(__FILE__)
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == gemspec_file) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ examples/ .git .github appveyor Gemfile]) ||
        # Internal planning docs — not shipped to gem consumers.
        f == "RAILS_RUNTIME_OBSERVABILITY_PLAN.md"
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "debug", "~> 1.0"
  spec.add_dependency "mcp", "~> 0.7"
  spec.add_dependency "webrick", "~> 1.9"

  spec.add_development_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
