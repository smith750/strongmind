# Design

## How I Understood the Problem

The system's goal is to save pushes made to Github repositories, using the publicly accessible, unauthorized API.  For each push, information is saved about the Github repository itself and the author of the push.

The system utilizes Ruby on Rails, in API mode, using Docker and Postgresql.  We will use Docker Compose to create a Postgres database for us.  Even though the Ruby on Rails application uses API mode, there are currently no controllers for it - none were necessary to achieve the goals of the project.

## Proposed Architecure

Three ActiveRecord classes are needed (and a fourth described in the rate limits section): PushEvent, Repository, Contributor.  PushEvent has very clear definitions for fields per Story 2 (github_push_id, github_event_id, ref, head, before) though we needed to add a handful of others to deal with rate limiting (repo_unenrichable and user_unenrichable most prominently).  Minimal information about the Repository and Contributor is pulled as well.  However, the full object json is stored in the database so we can add more fields later.

## Pull Service Object

"Repeatable" and "continuous" are two entry points over one shared piece of logic, not two different mechanisms. Repeatable is a rake task that runs the logic once, synchronously, and exits. Continuous is a Solid Queue job that runs the same logic and re-enqueues itself. See "Continuous Ingestion" below for how both are built on the same service object, including the escape (Solid Queue's own graceful shutdown on SIGTERM/SIGINT) and the sleep (a computed wait before the next self-enqueue).

The pull logic is encoded into a Service Object.  That way, it can be used in a number of contexts: in a Controller, in a Solid Queue job (already bundled via the Rails 8 default Gemfile - see "Continuous Ingestion" below), or a rake task where it could be run manually (though presumably one could also request against the controller).  Per the request document, we only need to have a way to ingest exposed via Docker commands.  We use both a rake task (repeatable) and a Solid Queue job (continuous), both calling the same service object - see "Continuous Ingestion" below.

The service object will look through all events but ONLY save events with a `type` of `PushEvent`.  It will then pull repository and author information as described in the Fan Out section.  All other events will be ignored.  As this loop goes, if the JSON for the event cannot be parsed and we cannot add all of the fields from the PushEvent, then we will log it as WARN, and continue to the next event.  If a request leads to an Error being thrown, it is caught immediately and  logged as an ERROR.  The maximum number of events per poll are queried.

If the request was meant to enrich a user or repository and the response was a 4xx error, then set the corresponding `repo_unenrichable` or `user_unenrichable` field on the push event and do not attempt again. A 4xx here means the repository or user is gone/renamed/otherwise permanently unreachable, as distinct from a transient failure - see the next section for how those are rescheduled.

In the service object logs at multiple points:
a) DEBUG before making a fetch request for events, a repository, or a user
b) An INFO if the request was successful
c) An INFO that a record could be properly parsed; a WARN if a record could not be properly parsed; an ERROR if the request failed entirely
d) An INFO every every record has been saved

## Rate limits

According to documentation, we are allowed to do an unauthorized poll of the site 60 times in an hour.  (https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2026-03-10; https://docs.github.com/en/rest/rate-limit/rate-limit?apiVersion=2026-03-10).  Given that, I believe we should also record each REST request we make against the Github API so we can time that.  This is the kind of data we could remove over time.

For each contributor and repository, the system checks if it has already saved that information in the database.  If has not, it pulls the information.  If it has, it uses the `etag` on the record from before to do a conditional request, per Github's documentation.  Therefore, the `etag` header from each request is also stored, and then passed along as an `if-none-match` header for the next request (either enqueued or immediate).  If we get back a 304, then we know that no new information is there. See Github's recommendations for conditional requests: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api?apiVersion=2026-03-10#handle-rate-limit-errors-appropriately

The system attempts to balance enriching user and repository information with recording events.  It does not split the budget into fixed per-purpose quotas; instead, polling runs on its own clock (gated by the `poll_interval` we stored from the last poll), and whatever budget is left between polls is spent draining the enrichment backlog.

The Request model therefore has the fields to help us poll appropriately and meet the budget between different kinds of requests.  This allows the system to achieve the goal of Extension A in terms of respecting Github's rate limiting.

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

One accepted tradeoff worth naming: `_unenrichable` is tracked per `PushEvent`, not per `github_repository_id`/`github_actor_id`. If five push events reference the same permanently-404ing repository, each of those five rows has to take its own failed enrichment attempt before all five are excluded from the backlog - one wasted request per affected event, not one per distinct repository. Given the exercise's scope we're accepting that rather than adding a separate per-repository/per-user "known bad" lookup.

## Key Tradeoffs and Assumptions

Neither entry point is expected to stay alive forever: the continuous chain can crash and get re-enqueued by the heartbeat, and every `docker compose run --rm ingest` invocation is a brand-new process. If budget state lived only in memory, a restart would forget how much of the hour's budget was already spent and could exceed Github's real limit right after restarting. Persisting the last known headers in the `Request` table means any process, cold-started or not, picks up from the same state - this also happens to be the restart-safety half of the idempotency extension, for free.

### Known gap

The rake task and the continuous chain both read-then-write `Request` rows independently; if both read the same near-the-floor remaining count before either writes its update, both could fire, overshooting the limit by one request. Given the small blast radius (bounded to +1, self-corrects at the next reset), we're documenting this as an accepted risk rather than adding a `pg_try_advisory_lock` for this exercise.

## What I intentionally did not build
* There is currently no reason to build a controller to request an ingestion be completed, and as such, it has not been built
* We kept a minimal list of fields on all objects pulled from Github - though `full_info` field on each contains the full JSON received from Github, so we can add more fields later if we need to.  The data model could become quite complex based on the information Github possibly hands to us, but that was not requested.
* We're not handling Events of any event type except for `PushEvent` - I mean, that's basically what the document directly says to do.
* We did not build Extension C (object storage for avatars/raw events). `full_info` on each model already retains the raw JSON in Postgres, which covers the audit/debug need Story 2 asks for without a second storage system to configure and reason about.
* Note about the rate limiting: while running repeatably, it is VERY difficult to get all of the repositories and users enriched because of the budget between the three.  Based on sampling, it seems as if most events are PushEvent, and given that reality, even in continuous mode, it would be difficult for all the enrichment to occur, at least in a single `jobs` or `web` container.  The best way to get around that would be: to get a Github token and do authenticated fetches.  This would allow us 5000 request an hour which would be much more amenable to enriching all the supporting data.
