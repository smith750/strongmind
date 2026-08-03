# Strongmind GitHub Ingest

Ingests `PushEvent`s from GitHub's public, unauthenticated `/events` API, enriches
each one with its repository and author, and persists everything to Postgres for
later querying. See `docs/DESIGN.md` for the design brief and
`docs/CLAUDE_IMPLEMENTATION.html` for phase-by-phase implementation notes.

## Requirements

Docker Desktop, running, on macOS. Everything else (Ruby, Postgres, gems) is
built into the containers - no local Ruby/Postgres install needed.

## Docker commands

### Start the system

```
docker compose up --build
```

Builds the app image and starts four containers:

* **`db`** - Postgres. Other services wait for its healthcheck before starting.
* **`migrate`** - runs `bin/rails db:prepare` once (creates/migrates both the
  primary and Solid Queue databases), then exits. `web` and `jobs` both wait for
  this to finish successfully before they start, so there's no race between them
  both trying to create the database at once on a fresh volume.
* **`web`** - the Rails server, on [http://localhost:3000](http://localhost:3000).
  There are no ingestion endpoints exposed over HTTP; it's here because the app
  is a Rails app, not because ingestion needs it.
* **`jobs`** - the Solid Queue supervisor (`bin/jobs`). This is what actually
  runs ingestion continuously and unattended: on startup it enqueues the first
  `GithubIngestJob`, which polls or enriches once, then reschedules itself, for
  as long as this container runs.

### Run ingestion once

```
docker compose run --rm ingest
```

Runs a single ingestion cycle (poll, or one enrichment) via the `ingest:once`
rake task, then exits. Same underlying logic (`Github::IngestCycle`) as the
continuous `jobs` service - useful for a one-off run, or for triggering a cycle
without leaving a background container running. Shares the same `db` container
and data as `jobs`/`web` if they're up.

### Run tests

```
docker compose run --rm test
```

Runs the RSpec suite (`bin/rspec`) against its own `strongmind_test` database
(same Postgres server, separate database - `web`/`jobs`/`ingest` are unaffected).
All GitHub API calls are mocked with WebMock; the test run makes no real network
requests.

### View logs

```
docker compose logs -f
```

Everything logs to stdout/stderr (no log files), so this shows all four
containers' output together. Add a service name to follow just one, e.g.
`docker compose logs -f jobs`.

### Stop / clean up

```
docker compose down       # stop containers, keep the Postgres volume
docker compose down -v    # stop containers AND wipe all data - fresh start
```

## How to verify it's working

1. Run `docker compose up --build` and then `docker compose logs -f jobs`.
2. Within the first few seconds you should see a poll against
   `https://api.github.com/events`, followed by `[Github::IngestCycle] cycle
   complete, decision=poll, ...`. If GitHub's feed had any push events in it,
   you'll also see `[Github::PollPushEvents] saved push event ...` lines.
3. Subsequent cycles will show `decision=enrich_repository` /
   `decision=enrich_user` as it works through the backlog, then `decision=idle`
   once caught up, or `decision=rate_limited` once the 60-requests/hour
   unauthenticated GitHub budget is used up (expect this within the first
   minute or two if the events feed is active - it's the same shared budget for
   polling and enrichment). A `rate_limited` cycle waits for the reset window
   from GitHub's own rate-limit headers, so don't expect continuous activity
   after the initial burst - that's expected, not a bug.
4. To check the data directly:
   ```
   docker compose exec db psql -U postgres -d strongmind_development
   ```
   then, for example:
   ```sql
   select count(*) from push_events;
   select count(*) from push_events where repository_id is null and not repo_unenrichable;
   -- rate-limit history:
   select purpose, status_code, ratelimit_remaining, created_at from requests order by created_at desc limit 10;
   ```

## Notes / things that would help a reviewer

* **`RATE_LIMIT_SAFETY_FLOOR`** is configurable (see
  `config/application.rb`/`Github::IngestCycle`), but it isn't currently wired
  into `docker-compose.yml`'s `environment:` blocks - setting it on the host
  before `docker compose up` won't reach the containers as-is. Works today for
  host-run commands (`RATE_LIMIT_SAFETY_FLOOR=2 bin/rails runner ...`). Adding
  it to `docker-compose.yml` would be a small follow-up if experimenting with it
  inside Docker is wanted.
* **`bin/jobs` and Apple Silicon/`pg`**: running `bin/jobs` directly on the host
  (outside Docker) has been observed to segfault on this machine, in the `pg`
  gem's native extension right after `fork()` - a known class of issue with
  `libpq`/OpenSSL and forking processes, not a bug in this app. Doesn't affect
  the Linux containers Docker Compose runs `bin/jobs` in. Only relevant if
  running `bin/jobs` outside Docker for some reason.
* `docker compose run --rm ingest` and the automatically-started `jobs`
  container share the same rate-limit budget (GitHub enforces one 60/hour limit
  regardless of which process calls it) - running both around the same time is
  fine, but expect them to compete for the same small budget rather than each
  getting their own 60 requests.
