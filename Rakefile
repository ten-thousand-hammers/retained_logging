require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

Rake::TestTask.new("test:integration") do |t|
  t.libs << "test"
  t.test_files = FileList["test/integration/*_test.rb"]
  t.warning = false
end

task default: [ :test, "test:integration" ]
