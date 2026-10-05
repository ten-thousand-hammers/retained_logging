Gem::Specification.new do |spec|
  spec.name = "retained_logging"
  spec.version = "0.1.1"
  spec.summary = "Bounded, private application log history and collection coverage"
  spec.authors = [ "Ten Thousand Hammers" ]
  spec.homepage = "https://github.com/ten-thousand-hammers/retained_logging"
  spec.license = "LicenseRef-Proprietary"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "test/**/*", "README.md", "LICENSE"].select { |path| File.file?(path) } }
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activesupport", "~> 8.1.3", ">= 8.1.3.1"
  spec.add_dependency "sqlite3", ">= 1.4", "< 3"
  spec.add_dependency "logger", "~> 1.6"
  # json 3.x made JSON.parse options keyword-only; ActiveSupport 8.1.3.1 still passes them positionally.
  spec.add_dependency "json", "~> 2.0"
  spec.add_dependency "openssl", ">= 3.2", "< 5"
  spec.add_dependency "securerandom", ">= 0.3", "< 1"
  spec.add_dependency "open3", "~> 0.2"
  spec.add_dependency "date", "~> 3.0"
  spec.add_dependency "time", "~> 0.3"
end
