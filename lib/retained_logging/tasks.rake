namespace :retained_logging do
  desc "Explicitly prepare the independent application evidence store"
  task prepare: :environment do
    result = RetainedLogging.rails_integration.history.prepare
    abort "Retained logging preparation failed: #{result.fetch('outcome')}" unless result.fetch("outcome") == "ok"
    puts "Retained logging prepared"
  end
end
