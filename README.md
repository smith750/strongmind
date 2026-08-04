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

Note that if you only want to run the ingestion job repeatably, not continuously, you should
not start the jobs container - which, as stated, is automatically kicked off by the
```
docker compose up --build
```
command.

Instead, you would run:
```
docker compose up --build db migrate web
```
That would only kick off the `db`, `migrate`, and `web` containers, not the `jobs` container,
meaning that the job would only run repeatably - ie, when the command above is run.

### Configuring the rate limit safety floor

`RATE_LIMIT_SAFETY_FLOOR` (see `config/application.rb`/`Github::IngestCycle`) is wired into
the `jobs` and `ingest` services' `environment:` blocks in `docker-compose.yml` - the only two
services that call `Github::IngestCycle` - defaulting to `5` if unset. It's read once at
process boot, so it can't be changed at runtime via a rake task argument or CLI flag, only by
setting the env var before the process starts:

```
RATE_LIMIT_SAFETY_FLOOR=2 docker compose up --build jobs
```

or, for a single one-off run:

```
docker compose run --rm -e RATE_LIMIT_SAFETY_FLOOR=2 ingest
```

### Run tests

```
docker compose run --rm test
```

Runs the RSpec suite (`bin/rspec`) against its own `strongmind_test` database
(same Postgres server, separate database - `web`/`jobs`/`ingest` are unaffected).
All GitHub API calls are mocked with WebMock; the test run makes no real network
requests.

### Rails console

```
docker compose exec web bin/rails console
```

Opens an interactive Rails console inside the already-running `web` container,
connected to the same `strongmind_development` database `web`/`jobs`/`ingest`
all read and write. Uses `exec`, not `run --rm`, so `docker compose up` needs
to already be up first.

### Database console

```
docker compose exec db psql -U postgres -d strongmind_development
```

Opens `psql` directly inside the `db` container against the primary
development database. Swap `-d strongmind_development` for
`-d strongmind_development_queue` to inspect Solid Queue's own tables
(`solid_queue_jobs`, etc.) instead, or `-d strongmind_test` /
`-d strongmind_test_queue` for the test databases.

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
4. To check the data directly, open the [database console](#database-console),
   then, for example:
   ```sql
   select count(*) from push_events;
   select count(*) from push_events where repository_id is null and not repo_unenrichable;
   -- rate-limit history:
   select purpose, status_code, ratelimit_remaining, created_at from requests order by created_at desc limit 10;
   ```
