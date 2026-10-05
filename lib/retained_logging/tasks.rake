namespace :retained_logging do
  desc "Check that web and job capture certified part of a recent window (default 15 minutes)"
  task :verify, [ :minutes ] => :environment do |_task, args|
    minutes = Integer(args[:minutes] || 15, exception: false)
    abort "Supply a lookback between 1 and 1440 minutes: retained_logging:verify[15]" unless minutes&.between?(1, 1440)
    report = RetainedLogging::Verification.new(history: RetainedLogging.rails_integration.history).call(minutes: minutes)
    abort "Retained logging verification failed: #{report.fetch('error')}" if report["error"]
    window = report.fetch("window")
    puts "Retained capture from #{window.fetch('start')} to #{window.fetch('end')}"
    report.fetch("components").each do |entry|
      status = entry["ok"] ? "ok" : "FAILED (#{entry['problems'].join(', ')})"
      delay = entry["collection_delay_seconds"]&.then { |seconds| "#{seconds.round(1)}s" } || "none"
      puts "  #{entry['component']}: #{status}; #{entry['covered_percent']}% covered, #{entry['gaps']} gaps, " \
        "checkpoint delay #{delay}, reasons #{entry['reasons'].join(', ').presence || 'none'}"
    end
    abort "Retained logging verification failed" unless report["ok"]
  end
end
