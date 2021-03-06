# frozen_string_literal: true

require 'optparse'
require 'logger'
require 'uri'

module Que
  module CommandLineInterface
    # Have a sensible default require file for Rails.
    RAILS_ENVIRONMENT_FILE = './config/environment.rb'

    class << self
      # Need to rely on dependency injection a bit to make this method cleanly
      # testable :/
      def parse(
        args:,
        output:,
        default_require_file: RAILS_ENVIRONMENT_FILE
      )

        options        = {}
        queues         = []
        log_level      = 'info'
        log_internals  = false
        poll_interval  = 5
        connection_url = nil

        parser =
          OptionParser.new do |opts|
            opts.banner = 'usage: que [options] [file/to/require] ...'

            opts.on(
              '-h',
              '--help',
              "Show this help text.",
            ) do
              output.puts opts.help
              return 0
            end

            opts.on(
              '-i',
              '--poll-interval [INTERVAL]',
              Float,
              "Set maximum interval between polls for available jobs, " \
                "in seconds (default: 5)",
            ) do |i|
              poll_interval = i
            end

            opts.on(
              '-l',
              '--log-level [LEVEL]',
              String,
              "Set level at which to log to STDOUT " \
                "(debug, info, warn, error, fatal) (default: info)",
            ) do |l|
              log_level = l
            end

            opts.on(
              '-q',
              '--queue-name [NAME]',
              String,
              "Set a queue name to work jobs from. " \
                "Can be passed multiple times. " \
                "(default: the default queue only)",
            ) do |queue_name|
              queues << queue_name
            end

            opts.on(
              '-v',
              '--version',
              "Print Que version and exit.",
            ) do
              require 'que'
              output.puts "Que version #{Que::VERSION}"
              return 0
            end

            opts.on(
              '-w',
              '--worker-count [COUNT]',
              Integer,
              "Set number of workers in process (default: 6)",
            ) do |w|
              options[:worker_count] = w
            end

            opts.on(
              '--connection-url [URL]',
              String,
              "Set a custom database url to connect to for locking purposes.",
            ) do |url|
              connection_url = url
            end

            opts.on(
              '--log-internals',
              "Log verbosely about Que's internal state. " \
                "Only recommended for debugging issues",
            ) do |l|
              log_internals = true
            end

            opts.on(
              '--maximum-buffer-size [SIZE]',
              Integer,
              "Set maximum number of jobs to be locked and held in this " \
                "process awaiting a worker (default: 8)",
            ) do |s|
              options[:maximum_buffer_size] = s
            end

            opts.on(
              '--minimum-buffer-size [SIZE]',
              Integer,
              "Set minimum number of jobs to be locked and held in this " \
                "process awaiting a worker (default: 2)",
            ) do |s|
              options[:minimum_buffer_size] = s
            end

            opts.on(
              '--wait-period [PERIOD]',
              Float,
              "Set maximum interval between checks of the in-memory job queue, " \
                "in milliseconds (default: 50)",
            ) do |p|
              options[:wait_period] = p
            end

            opts.on(
              '--worker-priorities [LIST]',
              Array,
              "List of priorities to assign to workers, " \
                "unspecified workers take jobs of any priority (default: 10,30,50)",
            ) do |p|
              options[:worker_priorities] = p.map(&:to_i)
            end
          end

        parser.parse!(args)

        if args.length.zero?
          if File.exist?(default_require_file)
            args << default_require_file
          else
            output.puts <<-OUTPUT
You didn't include any Ruby files to require!
Que needs to be able to load your application before it can process jobs.
(Or use `que -h` for a list of options)
OUTPUT
            return 1
          end
        end

        args.each do |file|
          begin
            require file
          rescue LoadError
            output.puts "Could not load file '#{file}'"
            return 1
          end
        end

        Que.logger ||= Logger.new(STDOUT)

        if log_internals
          Que.internal_logger = Que.logger
        end

        begin
          Que.get_logger.level = Logger.const_get(log_level.upcase)
        rescue NameError
          output.puts "Unsupported logging level: #{log_level} (try debug, info, warn, error, or fatal)"
          return 1
        end

        if queues.any?
          queues_hash = {}

          queues.each do |queue|
            name, interval = queue.split('=')
            p              = interval ? Float(interval) : poll_interval

            Que.assert(p > 0.01) { "Poll intervals can't be less than 0.01 seconds!" }

            queues_hash[name] = p
          end

          options[:queues] = queues_hash
        end

        options[:poll_interval] = poll_interval

        if connection_url
          uri = URI.parse(connection_url)

          options[:connection] =
            PG::Connection.open(
              host:     uri.host,
              user:     uri.user,
              password: uri.password,
              port:     uri.port || 5432,
              dbname:   uri.path[1..-1],
            )
        end

        locker =
          begin
            Que::Locker.new(options)
          rescue => e
            output.puts(e.message)
            return 1
          end

        # It's a bit sloppy to use a global for this when a local variable would
        # do, but we want to stop the locker from the CLI specs, so...
        $stop_que_executable = false
        %w[INT TERM].each { |signal| trap(signal) { $stop_que_executable = true } }

        loop do
          sleep 0.01
          break if $stop_que_executable || locker.stopping?
        end

        output.puts ''
        output.puts "Finishing Que's current jobs before exiting..."

        locker.stop!

        output.puts "Que's jobs finished, exiting..."
        return 0
      end
    end
  end
end
