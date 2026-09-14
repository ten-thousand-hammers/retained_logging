module RetainedLogging
  # The shared-volume lock survives a collector stall, but not its owner's exit.
  # Never unlink an open lifecycle's file: all observers must lock the same inode.
  class ProcessOwner
    attr_reader :id

    def self.path(database, id)
      "#{database}.owners/#{id}"
    end

    def initialize(database, id)
      @id = id
      directory = "#{database}.owners"
      begin
        Dir.mkdir(directory, 0700)
      rescue Errno::EEXIST
        # All containers use the same directory beside the history database.
      end
      @file = File.open(self.class.path(database, id), File::RDWR | File::CREAT | File::EXCL, 0600)
      @file.close_on_exec = true
      @file.flock(File::LOCK_EX | File::LOCK_NB)
    rescue StandardError
      close
      raise
    end

    def close
      # Closing an inherited descriptor must not explicitly unlock the parent.
      @file&.close unless @file&.closed?
    end

    def self.with_abandoned(database, id, legacy: false)
      File.open(path(database, id), File::RDWR) do |file|
        yield if file.flock(File::LOCK_EX | File::LOCK_NB)
      end
    rescue Errno::ENOENT
      # Legacy lifecycles have no ownership proof. Never infer death from age.
      yield if legacy
    end
  end
end
