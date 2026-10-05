require "active_record"

module RetainedLogging
  # Every store record uses this connection, never the host's primary pool, so
  # writes stay independent of application transactions. Rails hosts name the
  # database through config.retained_logging.database; other callers use
  # establish_connection directly.
  class Record < ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "retained_logging_"
  end

  # One collector lifecycle: a process identity under a scope and component.
  # seen_at advances with every write, so cleanup can tell a lifecycle whose
  # owner stopped writing from one that is still running.
  class Lifecycle < Record
    has_many :events
    has_many :checkpoints
    has_one :completion
  end

  # One captured occurrence. Rows carry a pattern identifier, never message text.
  class Event < Record
    belongs_to :lifecycle
  end

  # A checkpoint certifies only its explicit interval. Gaps are never filled.
  class Checkpoint < Record
    belongs_to :lifecycle
  end

  # Completions are immutable and have their own sequence, so a read snapshot
  # can exclude lifecycles that ended after it began.
  class Completion < Record
    belongs_to :lifecycle
  end

  # One bounded sample of the first message that produced each identifier.
  class Sample < Record
  end
end
