namespace :retained_logging do
  desc "Explicitly prepare the independent application evidence store"
  task prepare: :environment do
    result = RetainedLogging.rails_integration.history.prepare
    abort "Retained logging preparation failed: #{result.fetch('outcome')}" unless result.fetch("outcome") == "ok"
    puts "Retained logging prepared"
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
