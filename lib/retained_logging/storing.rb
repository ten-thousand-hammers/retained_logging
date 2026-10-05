module RetainedLogging
  STORING = :retained_logging_storing

  # Marks work the history store does on this fiber. Its own database logging
  # reaches the application logger like any other line, and capture must not
  # record it, or every write would try to write again.
  def self.storing
    previous = Thread.current[STORING]
    Thread.current[STORING] = true
    yield
  ensure
    Thread.current[STORING] = previous
  end

  def self.storing?
    Thread.current[STORING] == true
  end
end
