module Que
  module SQL
    STATEMENTS = {
      get_job: %{
        SELECT *
        FROM %{table}
        WHERE priority = $1::smallint
        AND   run_at   = $2::timestamptz
        AND   job_id   = $3::bigint
      },

      # Locks a job using a Postgres recursive CTE [1].
      #
      # As noted by the Postgres documentation, it may be slightly easier to
      # think about this expression as iteration rather than recursion, despite
      # the `RECURSION` nomenclature defined by the SQL standards committee.
      # Recursion is used here so that jobs in the table can be iterated one-by-
      # one until a lock can be acquired, where a non-recursive `SELECT` would
      # have the undesirable side-effect of locking multiple jobs at once. i.e.
      # Consider that the following would have the worker lock *all* unlocked
      # jobs:
      #
      #   SELECT (j).*, pg_try_advisory_lock((j).job_id) AS locked
      #   FROM que_jobs AS j;
      #
      # The CTE will initially produce an "anchor" from the non-recursive term
      # (i.e. before the `UNION`), and then use it as the contents of the
      # working table as it continues to iterate through `que_jobs` looking for
      # a lock. The jobs table has a sort on (priority, run_at, job_id) which
      # allows it to walk the jobs table in a stable manner. As noted above, the
      # recursion examines one job at a time so that it only ever acquires a
      # single lock.
      #
      # The recursion has two possible end conditions:
      #
      # 1. If a lock *can* be acquired, it bubbles up to the top-level `SELECT`
      #    outside of the `job` CTE which stops recursion because it is
      #    constrained with a `LIMIT` of 1.
      #
      # 2. If a lock *cannot* be acquired, the recursive term of the expression
      #    (i.e. what's after the `UNION`) will return an empty result set
      #    because there are no more candidates left that could possibly be
      #    locked. This empty result automatically ends recursion.
      #
      # Also note that we don't retrieve all the job information in poll_jobs
      # due to a race condition that could result in jobs being run twice. If
      # this query took its MVCC snapshot while a job was being processed by
      # another worker, but didn't attempt the advisory lock until it was
      # finished by that worker, it could return a job that had already been
      # completed. Once we have the lock we know that a previous worker would
      # have deleted the job by now, so we use get_job to retrieve it. If it
      # doesn't exist, no problem.
      #
      # [1] http://www.postgresql.org/docs/devel/static/queries-with.html
      #
      # Thanks to RhodiumToad in #postgresql for help with the original version
      # of the job lock CTE.

      poll_jobs: %{
        WITH RECURSIVE jobs AS (
          SELECT (j).*, pg_try_advisory_lock((j).job_id) AS locked
          FROM (
            SELECT j
            FROM %{table} AS j
            WHERE NOT job_id = ANY($1::integer[])
            AND run_at <= now()
            ORDER BY priority, run_at, job_id
            LIMIT 1
          ) AS t1
          UNION ALL (
            SELECT (j).*, pg_try_advisory_lock((j).job_id) AS locked
            FROM (
              SELECT (
                SELECT j
                FROM %{table} AS j
                WHERE NOT job_id = ANY($1::integer[])
                AND run_at <= now()
                AND (priority, run_at, job_id) > (jobs.priority, jobs.run_at, jobs.job_id)
                ORDER BY priority, run_at, job_id
                LIMIT 1
              ) AS j
              FROM jobs
              WHERE jobs.job_id IS NOT NULL
              LIMIT 1
            ) AS t1
          )
        )
        SELECT priority, run_at, job_id
        FROM jobs
        WHERE locked
        LIMIT $2::integer
      },

      reenqueue_job: %{
        WITH deleted_job AS (
          DELETE FROM %{table}
            WHERE priority = $1::smallint
            AND   run_at   = $2::timestamptz
            AND   job_id   = $3::bigint
        )
        INSERT INTO %{table}
        (priority, job_class, run_at, args)
        VALUES
        ($1::smallint, $4::text, $5::timestamptz, $6::json)
        RETURNING *
      },

      check_job: %{
        SELECT 1 AS one
        FROM   %{table}
        WHERE  priority = $1::smallint
        AND    run_at   = $2::timestamptz
        AND    job_id   = $3::bigint
      },

      set_error: %{
        UPDATE %{table}
        SET error_count = $1::integer,
            run_at      = now() + $2::bigint * '1 second'::interval,
            last_error  = $3::text
        WHERE priority  = $4::smallint
        AND   run_at    = $5::timestamptz
        AND   job_id    = $6::bigint
      },

      insert_job: %{
        INSERT INTO %{table}
        (priority, run_at, job_class, args)
        VALUES
        (coalesce($1, 100)::smallint, coalesce($2, now())::timestamptz, $3::text, coalesce($4, '[]')::json)
        RETURNING *
      },

      destroy_job: %{
        DELETE FROM %{table}
        WHERE priority = $1::smallint
        AND   run_at   = $2::timestamptz
        AND   job_id   = $3::bigint
      },

      clean_lockers: %{
        DELETE FROM que_lockers
        WHERE pid = pg_backend_pid()
        OR pid NOT IN (SELECT pid FROM pg_stat_activity)
      },

      register_locker: %{
        INSERT INTO que_lockers
        (pid, worker_count, ruby_pid, ruby_hostname, listening)
        VALUES
        (pg_backend_pid(), $1::integer, $2::integer, $3::text, $4::boolean);
      },

      job_stats: %{
        SELECT job_class,
               count(*)                    AS count,
               count(locks.job_id)         AS count_working,
               sum((error_count > 0)::int) AS count_errored,
               max(error_count)            AS highest_error_count,
               min(run_at)                 AS oldest_run_at
        FROM %{table}
        LEFT JOIN (
          SELECT (classid::bigint << 32) + objid::bigint AS job_id
          FROM pg_locks
          WHERE locktype = 'advisory'
        ) locks USING (job_id)
        GROUP BY job_class
        ORDER BY count(*) DESC
      },

      job_states: %{
        SELECT %{table}.*,
               pg.ruby_hostname,
               pg.ruby_pid
        FROM %{table}
        JOIN (
          SELECT (classid::bigint << 32) + objid::bigint AS job_id, que_lockers.*
          FROM pg_locks
          JOIN que_lockers USING (pid)
          WHERE locktype = 'advisory'
        ) pg USING (job_id)
      },
    }

    # Clean up these statements so that logs are clearer.
    STATEMENTS.keys.each do |key|
      STATEMENTS[key] = STATEMENTS[key].strip.gsub(/\s+/, ' ').freeze
    end
    STATEMENTS.freeze

    class << self
      STATEMENTS.each_key do |key|
        define_method key do |variables = {}|
          STATEMENTS[key] % variables
        end
      end
    end
  end
end
