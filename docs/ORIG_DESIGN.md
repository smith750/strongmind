# Design

Our goal is to save pushes made to Github repositories, using the publicly accessible, unauthorized API.  For each push, we want to save information about the Github repository itself and the author of the push.

We were asked to use Ruby on Rails, in API mode, using Docker and Postgresql.  We will use Docker Compose to create a Postgres database for us.

We need three ActiveRecord classes (and a fourth described in the rate limits section): PushEvent, Repository, Contributor.  PushEvent has very clear definitions for fields - we will only pull those; the rest, for now, we'll consider YAGNI.  We will also pull minimal information about the Repository and Contributor.  However, we will store the full object json in the database so we can add more fields later.

Let's describe each model then:

PushEvent (as described in requirements):
1. sequential id & timestamps
2. github_push_id - string
3. github_event_id - string - globally unique key from github, should have a unique constraint
4. github_repository_id - string
5. ref - string
6. head - string
7. before - string
8. github_actor_id - string - a way to reference actor so we can add the author id after its request
9. github_repository_id - string - a way to reference repository to we can add the repository id after its request
10. full_info - text (JSON)
11. repository_id - number - reference to Repository
12. author_id - number - reference to User
13. repo_unenrichable - boolean - did we receive a 4xx error while attempting to enrich the repository information? If true, then don't attempt to enrich again.
14. user_unenrichable - boolean - did we receive a 4xx error while attempting to enrich the repository information?  If true, then don't attempt to enrich again.

Repository
1. sequential id & timestamps
2. github_repository_id - string (should have a unique constraint and index)
3. full_name - string
4. html_url - string
5. description - text
6. url - string
7. last_etag - string - the etag of the previous request we made about the URL.  If nothing has changed, Github will return a 304 response and we'll know we don't need to update anything.
8. full_info - text (JSON)
9. has_many :push_events

User
1. sequential id & timestamps
2. github_user_id - string (should have a unique constraint and index)
3. login - string
4. avatar_url - string
5. user_url - string
6. html_url - string
7. last_etag - string - see explanation in the Repository model
8. full_info - text (JSON)
9. has_many :push_events

"Repeatable" and "continuous" are two entry points over one shared piece of logic, not two different mechanisms. Repeatable is a rake task that runs the logic once, synchronously, and exits. Continuous is a Solid Queue job that runs the same logic and re-enqueues itself. See "Continuous Ingestion" below for how both are built on the same service object, including the escape (Solid Queue's own graceful shutdown on SIGTERM/SIGINT) and the sleep (a computed wait before the next self-enqueue).

## Pull Service Object

We're going to encode the pull logic in a Service Object.  That way, we can use it in a number of contexts: in a Controller, in a Solid Queue job (already bundled via the Rails 8 default Gemfile - see "Continuous Ingestion" below), or a rake task where it could be run manually (though presumably one could also request against the controller).  Per the request document, we only need to have a way to ingest exposed via Docker commands.  We use both a rake task (repeatable) and a Solid Queue job (continuous), both calling the same service object - see "Continuous Ingestion" below.

The service object will look through all events but ONLY save events with a `type` of `PushEvent`.  It will then pull repository and author information as described in the Fan Out section.  All other events will be ignored.

As this loop goes, if the JSON for the event cannot be parsed and we cannot add all of the fields from the PushEvent, then we will log it as WARN, and continue to the next event

If a request leads to an Error being thrown, we will catch it immediately, log it as an ERROR, and move on to the next request.

We will send a query variable of `?per_page=100` during event requests to capture the maximum number of events we can manage.

If the request was meant to enrich a user or repository and the response was a 4xx error, then set the corresponding `repo_unenrichable` or `user_unenrichable` field on the push event and do not attempt again. A 4xx here means the repository or user is gone/renamed/otherwise permanently unreachable, as distinct from a transient failure - see the next section for how those are rescheduled.

In the service object will log at multiple points:
a) DEBUG before making a fetch request for events, a repository, or a user
b) An INFO if the request was successful
c) An INFO that a record could be properly parsed; a WARN if a record could not be properly parsed; an ERROR if the request failed entirely
d) An INFO every every record has been saved

## Rate limits

According to documentation, we are allowed to do an unauthorized poll of the site 60 times in an hour.  (https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2026-03-10; https://docs.github.com/en/rest/rate-limit/rate-limit?apiVersion=2026-03-10).  Given that, I believe we should also record each REST request we make against the Github API so we can time that.  This is the kind of data we could remove over time.

The request will tell us how long we must wait to make the next request.  We need to store that.  When our application receives a request to request more events, it will check the latest request we've made and see if we can make another request again.  If we can't, then we will enqueue a time to make a request; if we can, we'll make the request immediately.

We will also store the `etag` header from each request we store, and pass that along as an `if-none-match` header for the next request (either enqueued or immediate).  If we get back a 304, then we know that no new information is there. See Github's recommendations for conditional requests: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api?apiVersion=2026-03-10#handle-rate-limit-errors-appropriately

The Request model therefore looks like:

Request
1. sequential id & timestamps (we need an index on created_at since we'll be querying against that.)
2. url - string
3. etag - string
4. retry_after - int
5. ratelimit_remaining - int
6. ratelimit_reset - int
7. poll_interval - int - the number of seconds before we can poll any Github event again, defaults to 0 seconds but uses the X-Poll-Interview response header if it was returned from the request.
8. purpose - enum of either { poll: 0, enrich_repo: 1, enrich_user: 2}
9. status_code - integer - the HTTP status code of the response, in order to see 304s and make the next request right away.

See this section in Github for further explanation: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api?apiVersion=2026-03-10#handle-rate-limit-errors-appropriately

All of this is to achieve the goal of Extension A in terms of respecting Github's rate limiting.

## Fan Out

We'd like to limit the number of requests which we make and if we have to make multiple requests to pull contributors or repository information to be minimal.

Therefore, for each contributor and repository, we're going to see if we have already saved that information in the database.  If we haven't, we will pull the information.  If we have, we'll use the `etag` on the record from before to do a conditional request, per Github's documentation.

We are not splitting the budget into fixed per-purpose quotas (e.g. a fixed N/hour for polling vs. M/hour for enrichment) - Github enforces a single shared 60-requests/hour limit across every endpoint, so there's only one number to track. Instead we apply a priority rule on top of that single number: polling runs on its own clock (gated by the `poll_interval` we stored from the last poll), and whatever budget is left between polls is spent draining the enrichment backlog. See "Continuous Ingestion" below for the exact decision algorithm.

## Continuous Ingestion

Both "repeatable" and "continuous" are entry points over one shared service object - call it `Github::IngestCycle` - that performs at most one HTTP request per call (poll, enrich a repository, or enrich a user) and returns. It has no knowledge of jobs, queues, or scheduling.

* **Repeatable** - a rake task (`ingest`) calls `Github::IngestCycle` directly and synchronously, once, then exits. This is what `docker compose run --rm ingest` runs, and it works standalone with no dependency on a background worker being up.
* **Continuous** - a Solid Queue job (`GithubIngestJob`) calls `Github::IngestCycle`, then computes a wait (see below) and re-enqueues itself with `perform_later(wait: ...)`. As long as `bin/jobs` is running, the chain keeps going unattended. Its "escape" is Solid Queue's own graceful shutdown on SIGTERM/SIGINT - the in-flight cycle finishes and no new one is claimed. Its "sleep" is the computed wait before the next self-enqueue.

A `config/recurring.yml` entry acts only as a heartbeat (e.g. hourly): if the self-rescheduling chain ever dies from an unhandled error, this re-enqueues `GithubIngestJob` so ingestion doesn't stay silently stalled. It is not the primary driver of pacing - the job's own self-rescheduling is.

### Deciding what to do this cycle

On every call, `Github::IngestCycle`:

1. Reads the most recent `Request` row (any purpose) for `ratelimit_remaining` / `ratelimit_reset` - the ground truth from Github's last response to us, whichever entry point made it.
2. Reads the most recent `Request` row where `purpose = poll` to compute `next_allowed_poll_at = created_at + poll_interval`.
3. Decides:
   * If `ratelimit_remaining` is at or below a safety floor (e.g. 5) - do nothing, and the caller reschedules for `ratelimit_reset`.
   * Else if `Time.current >= next_allowed_poll_at` - poll `/events`.
   * Else if an enrichment backlog exists (`PushEvent.where(repository_id: nil, repo_unenrichable: false)` or `.where(author_id: nil, user_unenrichable: false)`) - enrich the oldest backlog item. The `_unenrichable` filters matter here - without them, a push event whose repo or user permanently 4xx'd would keep showing up in this query forever, since `repository_id`/`author_id` stay `nil` with no Repository/User row to ever link to. The `_unenrichable` flags are what stop that.
   * Else - nothing to do, and the caller reschedules a short idle wait.
4. Whatever request was actually made, persists the response's headers as a new `Request` row - this is what step 1 reads next cycle. If the request errored (5xx, network failure - not a 4xx enrichment failure, which is handled above by the unenrichable flags instead), no `Request` row is written for it, and the cycle logs the error; the caller reschedules with the same computed wait as any other cycle rather than a special backoff, since the next cycle will simply attempt the same work again.

If no `Request` row exists yet (first run ever), assume full budget and poll immediately.

One accepted tradeoff worth naming: `_unenrichable` is tracked per `PushEvent`, not per `github_repository_id`/`github_actor_id`. If five push events reference the same permanently-404ing repository, each of those five rows has to take its own failed enrichment attempt before all five are excluded from the backlog - one wasted request per affected event, not one per distinct repository. Given the exercise's scope we're accepting that rather than adding a separate per-repository/per-user "known bad" lookup.

### Why persist to Postgres instead of holding state in memory

Neither entry point is expected to stay alive forever: the continuous chain can crash and get re-enqueued by the heartbeat, and every `docker compose run --rm ingest` invocation is a brand-new process. If budget state lived only in memory, a restart would forget how much of the hour's budget was already spent and could exceed Github's real limit right after restarting. Persisting the last known headers in the `Request` table means any process, cold-started or not, picks up from the same state - this also happens to be the restart-safety half of the idempotency extension, for free.

### Known gap

The rake task and the continuous chain both read-then-write `Request` rows independently; if both read the same near-the-floor remaining count before either writes its update, both could fire, overshooting the limit by one request. Given the small blast radius (bounded to +1, self-corrects at the next reset), we're documenting this as an accepted risk rather than adding a `pg_try_advisory_lock` for this exercise.

### Docker / Rails wiring this requires

* `config.active_job.queue_adapter = :solid_queue` is currently only set for `production` - it needs to also apply wherever the continuous chain runs (development, since that's what docker-compose uses).
* `docker-compose.yml` needs a `jobs` service running `bin/jobs` (the Solid Queue supervisor) alongside `web`.
* `config/recurring.yml` needs the heartbeat entry described above.
* `config/environments/development.rb` needs to log to STDOUT. Right now only `production.rb` sets `config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)` - development still uses Rails' default file logger (`log/development.log`). Since `docker-compose.yml` runs `RAILS_ENV: development`, every DEBUG/INFO/WARN/ERROR line from the Pull Service Object's logging plan would currently go to a file inside the container, invisible to `docker compose logs -f`. This is a required fix, not optional - the brief explicitly grades on `docker compose logs -f` showing system behavior.

## Phases

1. Create models
2. Create service object to pull a page of pushes (and save a request record)
3. Add logic to pull contributors
4. Add logic to pull repositories
5. Build the `Github::IngestCycle` budget/backlog decision logic described in "Continuous Ingestion"
6. Build the rake task ("repeatable") that calls `Github::IngestCycle` directly, once, and exits
7. Build the Solid Queue job ("continuous") that wraps `Github::IngestCycle` and self-reschedules; wire up `bin/jobs` as a docker-compose service and the `recurring.yml` heartbeat entry
8. Wire up the `ingest` and `test` docker-compose services (and confirm `jobs` starts under `docker compose up --build`) as described in "Docker Compose Wiring" above; verify all three reviewer commands work from a clean checkout
JAMES HERE Remaining phases: use rspec for tests, copy edit version of this document, log every loop cycle in GithubInjestJob, environment variable for how many event polls an hour

Every phase will be built using a TDD behavior so we can verify behavior as we complete each step.  Because of Github's request rate limits, we will always mock requests in tests.  We will write integration tests around the use of SolidQueue.


## Docker Compose Wiring

`docker-compose.yml` currently only defines `db` and `web`. It needs two more named services so the reviewer's exact commands work from a clean checkout, plus the `jobs` service already called for in "Continuous Ingestion":

* **`jobs`** - runs `bin/jobs` (the Solid Queue supervisor). Same build as `web` (`Dockerfile.dev`), same env pointing at `db`. Not profiled - it starts automatically under `docker compose up --build`, alongside `db` and `web`, since continuous ingestion is meant to run unattended as part of "the system," not as a one-off.
* **`ingest`** - runs `bin/rails db:prepare && bin/rails ingest:once` (the "repeatable" rake task from Phase 6). Same build/env as `web`. Given `profiles: ["tools"]` so `docker compose up --build` doesn't try to start it as a long-running service - `docker compose run --rm ingest` still works, since `run` targets a named service explicitly regardless of its profile.
* **`test`** - runs `bin/rails db:prepare && bin/rails test`, with `RAILS_ENV: test` (and `DATABASE_*` still pointing at the same `db` container - Rails keeps dev and test as separate databases on the same Postgres server via `database.yml`, so no second database service is needed). Also `profiles: ["tools"]`, for the same reason as `ingest`.

Both `ingest` and `test` re-run `db:prepare` defensively before their real command, in case a reviewer runs `docker compose run --rm ingest` (or `test`) without having brought `docker compose up` up first - it's a cheap, idempotent step either way.

## What I intentionally did not build
* There is currently no reason to build a controller to request an ingestion be completed, and as such, it has not been built
* We kept a minimal list of fields on all objects pulled from Github - though `full_info` field on each contains the full JSON received from Github, so we can add more fields later if we need to.  The data model could become quite complex based on the information Github possibly hands to us, but that was not requested.
* We're not handling Events of any event type except for `PushEvent` - I mean, that's basically what the document directly says to do.
* We did not build Extension C (object storage for avatars/raw events). `full_info` on each model already retains the raw JSON in Postgres, which covers the audit/debug need Story 2 asks for without a second storage system to configure and reason about.
