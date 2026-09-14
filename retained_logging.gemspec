Gem::Specification.new do |spec|
  spec.name = "retained_logging"
  spec.version = "0.1.0"
  spec.summary = "Bounded, private application log history and collection coverage"
  spec.authors = [ "Ten Thousand Hammers" ]
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "test/**/*", "README.md"].select { |path| File.file?(path) } }
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activesupport", "~> 8.1.3", ">= 8.1.3.1"
  spec.add_dependency "sqlite3", ">= 1.4", "< 3"
  spec.add_dependency "logger", "~> 1.6"
  spec.add_dependency "json", ">= 2", "< 4"
  spec.add_dependency "openssl", ">= 3.2", "< 5"
  spec.add_dependency "securerandom", ">= 0.3", "< 1"
  spec.add_dependency "open3", "~> 0.2"
  spec.add_dependency "date", "~> 3.0"
  spec.add_dependency "time", "~> 0.3"
end
