require 'forwardable'
require 'socket' # For Socket.gethostname

module Que
  class Error < StandardError; end

  begin
    require 'multi_json'
    JSON_MODULE = MultiJson
  rescue LoadError
    require 'json'
    JSON_MODULE = JSON
  end

  require_relative 'que/job'
  require_relative 'que/job_queue'
  require_relative 'que/locker'
  require_relative 'que/migrations'
  require_relative 'que/pool'
  require_relative 'que/recurring_job'
  require_relative 'que/result_queue'
  require_relative 'que/sql'
  require_relative 'que/version'
  require_relative 'que/worker'

  HASH_DEFAULT_PROC = proc { |hash, key| hash[key.to_s] if Symbol === key }

  INDIFFERENTIATOR = proc do |object|
    case object
    when Array
      object.each(&INDIFFERENTIATOR)
    when Hash
      object.default_proc = HASH_DEFAULT_PROC
      object.each { |key, value| object[key] = INDIFFERENTIATOR.call(value) }
      object
    else
      object
    end
  end

  SYMBOLIZER = proc do |object|
    case object
    when Hash
      object.keys.each do |key|
        object[key.to_sym] = SYMBOLIZER.call(object.delete(key))
      end
      object
    when Array
      object.map! { |e| SYMBOLIZER.call(e) }
    else
      object
    end
  end

  class << self
    extend Forwardable

    attr_accessor :logger, :error_handler
    attr_writer :pool, :log_formatter, :logger, :json_converter
    attr_reader :mode, :locker

    def connection=(connection)
      self.connection_proc =
        if connection.to_s == 'ActiveRecord'
          proc { |&block| ActiveRecord::Base.connection_pool.with_connection { |conn| block.call(conn.raw_connection) } }
        else
          case connection.class.to_s
            when 'Sequel::Postgres::Database' then connection.method(:synchronize)
            when 'ConnectionPool'             then connection.method(:with)
            when 'Pond'                       then connection.method(:checkout)
            when 'PG::Connection'             then raise "Que now requires a connection pool and can no longer use a plain PG::Connection."
            when 'NilClass'                   then connection
            else raise Error, "Que connection not recognized: #{connection.inspect}"
          end
        end
    end

    def connection_proc=(connection_proc)
      @pool = connection_proc && Pool.new(&connection_proc)
    end

    def pool
      @pool || raise(Error, "Que connection not established!")
    end

    def clear!
      execute "DELETE FROM que_jobs"
    end

    def job_stats(table: :que_jobs)
      execute SQL.job_stats(table: table)
    end

    def job_states(table: :que_jobs)
      execute SQL.job_states(table: table)
    end

    # Have to support create! and drop! in old migrations. They just created
    # and dropped the bare table.
    def create!
      migrate! version: 1
    end

    def drop!
      migrate! version: 0
    end

    def log(level: :info, **data)
      data = {lib: :que, hostname: Socket.gethostname, pid: Process.pid, thread: Thread.current.object_id}.merge(data)

      if l = logger
        begin
          if output = log_formatter.call(data)
            l.send level, output
          end
        rescue => e
          l.error "Error raised from Que.log_formatter proc: #{e.class}: #{e.message}\n#{e.backtrace}"
        end
      end
    end

    def logger
      @logger.respond_to?(:call) ? @logger.call : @logger
    end

    def log_formatter
      @log_formatter ||= JSON_MODULE.method(:dump)
    end

    def create_job_queue!(name)
      execute <<-SQL
        CREATE TABLE #{name}
        (
          priority smallint NOT NULL DEFAULT 100,
          run_at timestamp with time zone NOT NULL DEFAULT now(),
          job_id bigserial NOT NULL,
          job_class text NOT NULL,
          args json NOT NULL DEFAULT '[]'::json,
          error_count integer NOT NULL DEFAULT 0,
          last_error text,
          CONSTRAINT "#{name}_pkey" PRIMARY KEY (priority, run_at, job_id)
        );

        COMMENT ON TABLE #{name} IS '4';

        CREATE TRIGGER que_job_notify AFTER INSERT ON #{name} FOR EACH ROW EXECUTE PROCEDURE que_job_notify();
      SQL
    end

    # A helper method to manage transactions, used mainly by the migration
    # system. It's available for general use, but if you're using an ORM that
    # provides its own transaction helper, be sure to use that instead, or the
    # two may interfere with one another.
    def transaction
      pool.checkout do
        if pool.in_transaction?
          yield
        else
          begin
            execute "BEGIN"
            yield
          rescue => error
            raise
          ensure
            # Handle a raised error or a killed thread.
            if error || Thread.current.status == 'aborting'
              execute "ROLLBACK"
            else
              execute "COMMIT"
            end
          end
        end
      end
    end

    def mode=(mode)
      if @mode != mode
        case mode
        when :async
          @locker = Locker.new
        when :sync, :off
          if @locker
            @locker.stop
            @locker = nil
          end
        else
          raise Error, "Unknown Que mode: #{mode.inspect}"
        end

        log level: :debug, event: :mode_change, value: mode
        @mode = mode
      end
    end

    def json_converter
      @json_converter ||= SYMBOLIZER
    end

    # Copy some commonly-used methods here, for convenience.
    def_delegators :pool, :execute, :checkout, :in_transaction?
    def_delegators Job, :enqueue
    def_delegators Migrations, :db_version, :migrate!
  end
end
