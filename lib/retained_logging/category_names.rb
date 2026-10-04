module RetainedLogging
  # One place declares both names of the failed-request category: the name the
  # history store writes and accepts, and the name inspection clients are told.
  # Every path that stores, validates, filters or reports that category reads
  # these constants and the two converters below, so neither name can drift away
  # from the other. The store's schema.sql is static SQL the worker replays, so
  # its text is bound to FAILED_REQUESTS_STORED by a test rather than by a
  # reference. This file stays dependency-free: the read-only worker loads it
  # without RubyGems and with only sqlite3, json, time and date available.
  module CategoryNames
    FAILED_REQUESTS_STORED = "failed_requests"
    FAILED_REQUESTS_REPORTED = "request_failures"

    # The name the store holds rows under for a client selector. Every other
    # selector already names stored rows directly.
    def self.stored(selector)
      selector == FAILED_REQUESTS_REPORTED ? FAILED_REQUESTS_STORED : selector
    end

    # The name clients are told for a stored category. Every other stored
    # category is already reported under its own name.
    def self.reported(category)
      category == FAILED_REQUESTS_STORED ? FAILED_REQUESTS_REPORTED : category
    end
  end
end
