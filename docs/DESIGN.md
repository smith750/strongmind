# Design

Our goal is to save pushes made to Github repositories, using the publicly accessible, unauthorized API.  For each push, we want to save information about the Github repository itself and the author of the push.

We were asked to use Ruby on Rails, in API mode, using Docker and Postgresql.  We will use Docker Compose to create a Postgres database for us.

We need three ActiveRecord classes (and a fourth described in the rate limits section): Push, Repository, Contributor.  Push has very clear definitions for fields - we will only pull those; the rest, for now, we'll consider YAGNI.  We will also pull minimal information about the Repository and Contributor.

JAMES: don't update duplicates
JAMES: Only PushEvent items are processed
JAMES: Generate both sequence and an externally available UUID

JAMES: What does "Ingestion is repeatable or continuous" mean?  Have the ingestion in a loop until the rate limit is hit?
JAMES: remember logging

## Pull Service Object

We're going to encode the pull logic in a Service Object.  That way, we can use it in a number of contexts: in a Controller, in a cron job (Sidekik or GoodJob or some such), or a rake task where it could be run manually (though presumably one could also request against the controller).  We'll build out the controller method to do the pulls and the rake task - I believe that Docker will call the rake task.

## Rate limits

According to documentation, we are allowed to do an unauthorized poll of the site 60 times in an hour.  (https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2026-03-10; https://docs.github.com/en/rest/rate-limit/rate-limit?apiVersion=2026-03-10).  Given that, I believe we should also record each REST request we make against the Github API so we can time that.  This is the kind of data we could remove over time.

When a date limit is hit, we need to report an error.

## Fan Out

We'd like to limit the number of requests which we make and if we have to make multiple requests to pull contributors or repository information 

## Phases

1. Create models
2. Create service object to pull a page of pushes (and save a request record)
3. Add logic to pull contributors
4. Add logic to pull repositories
5. Build controller which performs the pull
6. Build rake task which performs the pull

Every phase will be built using a TDD behavior so we can verify behavior as we complete each step.




JAMES: how to hook up docker compose run --rm <ingest>
JAMES: how to hook up docker compose run --rm test
