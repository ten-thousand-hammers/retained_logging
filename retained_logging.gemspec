Gem::Specification.new do |spec|
  spec.name = "retained_logging"
  spec.version = "0.2.1"
  spec.summary = "Bounded, private application log history and collection coverage"
  spec.authors = [ "Ten Thousand Hammers" ]
  spec.homepage = "https://github.com/ten-thousand-hammers/retained_logging"
  spec.license = "LicenseRef-Proprietary"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "db/**/*", "test/**/*", "README.md", "LICENSE"].select { |path| File.file?(path) } }
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activesupport", "~> 8.1.3", ">= 8.1.3.1"
  # The host chooses and bundles the database adapter for the store.
  spec.add_dependency "activerecord", "~> 8.1.3", ">= 8.1.3.1"
  # json 3.x made JSON.parse options keyword-only; ActiveSupport 8.1.3.1 still passes them positionally.
  spec.add_dependency "json", "~> 2.0"
end
