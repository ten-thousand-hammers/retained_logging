namespace :retained_logging do
  desc "Explicitly prepare the independent application evidence store"
  task prepare: :environment do
    result = RetainedLogging.rails_integration.history.prepare
    abort "Retained logging preparation failed: #{result.fetch('outcome')}" unless result.fetch("outcome") == "ok"
    puts "Retained logging prepared"
  end

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

  desc "Close one legacy lifecycle after independently confirming its owner stopped"
  task :reconcile, [ :process_id, :stopped_at ] => :environment do |_task, args|
    begin
      stopped_at = Time.iso8601(args[:stopped_at])
    rescue ArgumentError, TypeError
      abort "Supply a process UUID and a confirmed UTC stop upper bound: retained_logging:reconcile[UUID,2026-09-14T18:00:00Z]"
    end
    result = RetainedLogging.rails_integration.history.reconcile_process(process_id: args[:process_id], stopped_at: stopped_at)
    abort "Retained lifecycle reconciliation failed: #{result.fetch('outcome')}" unless result.fetch("outcome") == "ok"
    puts "Retained lifecycle closed; its unobserved interval remains a gap"
  end
end
