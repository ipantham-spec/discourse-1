# RFC: A versioned JSON:API for Discourse

This is the RFC for our [REST API overhaul](https://dev.discourse.org/t/rest-api-overhaul-project-overview/187625).

Prior work:

- Prototype in the data-explorer plugin: [PR #40832](https://github.com/discourse/discourse/pull/40832), including full design & reasoning in markdown files
- Exploration logs: [Modernizing how we write APIs in Discourse](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394)

If you have suggestions/corrections, please post below, and I’ll handle integrating any changes.

## TL;DR

- A new API served under a global `/api/...` namespace (that's the proposal, see the open questions)
- JSON:API formats for requests and responses, so one shape everywhere, with related data side-loaded on request
- AMS serializers are replaced with a resource object: document shape and query surface (filters, sorts, includes, pagination) declared in one place
- Versioned by date, and the version header is mandatory. Controllers only implement the latest version, and dated version changes translate older requests and responses, a bit like AR migrations but for the wire, never for stored data
- Requests, responses and version changes are self-documenting: the reference docs and the changelog are generated from them
- Cursor pagination only: no page numbers, no offsets, no total counts
- Plugins can add namespaced relations and filters to core resources, but not modify their attributes
- The current API stays in place, the new one is opt-in per request

## Background

Our APIs are hand-rolled: AMS serializers, ad-hoc pagination, and a different response shape per endpoint, with related data side-loaded differently everywhere (see [this post](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/1)). Avoiding breaking changes is a best effort, and we fail regularly. And the documentation is written by hand, separately from the code, so it doesn’t always stay up to date (see [documentation update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/19)).

So instead of defining our own conventions, we're adopting [JSON:API](https://jsonapi.org/). It's a frozen spec, and it already standardizes what we do (more or less) by hand today: compound documents^[one response carrying the records asked for plus the related ones, in a single `included` array], `include`^[the parameter asking for those related records: `?include=user,groups`], sparse fieldsets^[`?fields[queries]=name,ran_at`, so a client can ask for only the attributes it needs], `filter`, `sort` and `page`. It's also what WarpDrive is designed around. And as its documents are type-tagged, with standard error pointers and reserved parameter families^[every resource carries a `type`; validation errors point at the attribute at fault with a JSON Pointer (`/data/attributes/name`); and the spec reserves the `include`, `fields`, `filter`, `sort` and `page` parameter names. So the versioning machinery can find and rewrite all of those generically, instead of needing per-endpoint wiring], the versioning machinery below stays relatively small.

## Goals

From the [project overview](https://dev.discourse.org/t/rest-api-overhaul-project-overview/187625):

1. Third parties can depend on our REST API without worrying about unexpected breaking changes.
2. Consistent formats for requests and responses, including common patterns like side-loading related data.
3. It’s easy for us (CDCK developers) to create and evolve APIs using these patterns.
4. The API is clearly documented and can be referenced by customer-facing teams as a major feature of Discourse.
5. Designed to avoid fundamental performance issues (e.g. cursor pagination instead of `LIMIT...OFFSET`).
6. Suited to integrate with our frontend app ([WarpDrive migration](https://dev.discourse.org/t/warpdrive-migration-project-overview/187528)).

## For integrators (using the API)

### Authentication

Nothing changes here, we keep the existing API key credentials (`Api-Key`/`Api-Username`). Authorization doesn't change either and keeps using our guardians: a resource declares the scope a caller can see, attributes can be restricted, and writes go through the usual service framework.

### Versioning

Every request must provide a version, which is a date:

```
Api-Version: 2026-07-08
```

The date snaps down to the nearest published version at or before it, and the resolved version is returned in the response header. Dates in the future, or before the API's first version, are rejected. Integrators send today's date once, store the value that comes back, and send that one from then on.

What the pin guarantees: nothing you already receive is removed, renamed, or reshaped. Additive changes (a new attribute, a new relationship, a new filter) aren't versioned and do reach every client, so clients should ignore what they don't know instead of rejecting it.

The header is mandatory, there's no `latest` mode and no default, and a request without it gets a `400` naming the current version. Without a pin, a client silently follows our changes, which is the problem we're trying to solve.

Breaking changes are published as dated version changes. Clients pinned before that date keep getting the old shape: attribute names, filter and sort keys, error pointers, and the documentation for their pin. Discourse itself only knows the latest shape: requests are migrated up to it before validation, and responses are translated back down when they're serialized. Endpoints can also be deprecated (which sends the standard `Deprecation` header) and removed later on a date, older pins being still served until they move.

Plugins shipping independently from core have their own version list, as they change without touching core's. Clients stay at their pin unless they use an override:

```
Api-Version: 2026-07-08; some-plugin=2026-07-15
```

Plugins bundled with core use core's version list instead, as they ship and deploy together. Details in the [versioning update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/13) and the [plugins update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/17).

### Requests and responses

Responses are JSON:API documents (`application/vnd.api+json`): typed resources with relationships, related data returned on request through `include`, `fields[type]` to pick attributes, and `filter[...]` / `sort` on listings. A relationship shows up when it's been included, `include` is how related data is reached.

```json
{
  "data": [
    {
      "id": "1",
      "type": "queries",
      "attributes": {
        "name": "Top referred topics",
        "query": "SELECT id, title FROM topics ORDER BY like_count DESC LIMIT 10",
        "ran_at": "2026-07-01T10:00:00.000Z"
      },
      "relationships": {
        "user": { "data": { "id": "1", "type": "users" } },
        "groups": { "data": [{ "id": "1", "type": "groups" }] }
      },
      "meta": { "page": { "cursor": "…" } }
    }
  ],
  "included": [
    { "id": "1", "type": "users", "attributes": { "usernames": ["query_master"] } },
    { "id": "1", "type": "groups", "attributes": { "name": "sql_writers" } }
  ],
  "links": { "prev": null, "next": "…" }
}
```

One request returns the list, its authors and their groups, instead of a request per author. It's also the format WarpDrive consumes natively.

Writes take a JSON:API document too (`data.type` plus `attributes`, relationships as linkage) and follow the spec's methods: `POST` to create, `PATCH` to update.

### Pagination

Collections use the JSON:API [cursor pagination profile](https://jsonapi.org/profiles/ethanresnick/cursor-pagination): `page[size]`, `page[after]`, `page[before]`, and `links.prev` / `links.next` to follow. There's no offset pagination, as `LIMIT...OFFSET` gets slower when the offset grows. The trade-off for integrators: no page numbers, no jumping to page N, and no total count either (counting a filtered set is exactly the kind of query that gets expensive as the data grows). Explained in the [versioning update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/13).

### Errors

Errors are JSON:API error documents. On listings, unknown filters, sorts, includes or page parameters are rejected with a `400` naming what wasn't recognized, instead of being ignored. Validation failures return `422` with a JSON Pointer per invalid attribute, using the names of the client's pinned version.

### Documentation

The reference documentation is generated from the same declarations that serve the API, so the two can't diverge, and it's versioned: selecting a date shows the API as that pin sees it. There's one document per owner (core, then one per plugin), each with its own changelog. Described in the [documentation update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/19), and you can browse the generated docs for the prototype here:

<https://raw.githack.com/discourse/discourse/loic/json-api-experiments/plugins/discourse-data-explorer/openapi-docs.html>

## For developers (writing endpoints)

### Resource classes

A resource class declares the document shape and the query surface in one place, including the ActiveRecord scope a caller may see. Attribute types are required: the documentation is generated from them, and it's the same type vocabulary service contracts already use.

```ruby
class QueryResource < ApplicationResource
  type :queries
  description "A saved Data Explorer SQL query: its source, sharing groups, and last-run information."

  attribute :name, :string, writable: true, example: "Top referred topics"
  attribute :query, :string, writable: true, description: "The SQL source of the query.", &:sql
  attribute :ran_at, :datetime, &:last_run_at

  has_one :user, resource: UserResource
  has_many :groups, resource: GroupResource

  includes :user, :groups, "user.groups"
  default_sort ran_at: :desc
  page max: 100, default: 20

  filter :q, :string, description: "Matches the query's name or description." do |scope, value|
    # ...
  end
  sort :ran_at, column: :last_run_at, nulls: :last

  base_scope { ... }   # what this caller is allowed to see
end
```

### Controllers

A controller names its resource. Reads (`index`, `show`) are handled by the framework, writes stay explicit with `Service::Base`, as they're business actions:

```ruby
class QueriesController < BaseController
  resource QueryResource

  def create
    Query::Create.call(service_params) do
      on_success { |query:| render_resource(query, status: :created) }
      on_failed_policy(:can_create_query) { raise Discourse::InvalidAccess }
      on_failed_contract { |contract| render_validation_errors(contract.errors) }
      # ...
    end
  end
end
```

Filtering, sorting, attribute selection, pagination, `include` handling, rejection of unknown parameters, version resolution and translation are handled once, for every endpoint.

### Breaking changes

When an attribute has to be renamed (for example), the code just moves to the new name, and the old one goes into a dated version change:

```ruby
class RenameQueriesSqlToQuery < VersionChange
  version "2026-06-15"
  description "The `sql` attribute of the queries resource is renamed to `query`."

  resource :queries do
    renamed_attribute from: :sql, to: :query
  end
end
```

That declaration covers the response, the request body, sort and filter keys derived from the attribute, attribute selection, error pointers, the changelog entry and the documentation of earlier versions. The date is the day the change happens, several changes can share one date, and once shipped a date never moves.

Renames are the common case, not the only one. When the shape moves and not just the name, the declaration handles the conversion both ways. Here `username` (a string) became `usernames` (an array), with `old_type:` so the old documentation and examples stay right:

```ruby
resource :users do
  renamed_attribute from: :username,
                    to: :usernames,
                    up: ->(username) { [username] },
                    down: ->(usernames) { usernames.first },
                    old_type: :string
end
```

`down:` runs for responses, so an old client still gets a string, and `up:` for requests, so it can still send one. Filters and sorts have their own keywords, as their keys aren't always tied to an attribute. Top-level members (`meta`, `links`) have a `document` scope. Endpoints can be deprecated and removed on a date. And for whatever the keywords don't cover, a change can carry plain `up`/`down` blocks working on the document itself, which reads a bit like an AR migration.

What stays out: these transforms only reshape a representation, the same facts expressed differently. A change to what an endpoint actually does, or to data we don't produce anymore, isn't a version change but a new endpoint. And stored data is never versioned. The [versioning update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/13) goes through the five changes the prototype ships.

### Plugins

Plugins declare their contributions in one block in `plugin.rb`. They attach data to core types as relationships instead of adding attributes to core payloads, so core responses are the same whether the plugin is installed:

```ruby
jsonapi namespace: "run-stats" do
  register_relationship(:queries, resource: StatsResource, description: "…") { |query| ... }
  register_filter(:queries, :stale, :boolean, description: "…") { |scope, value| ... }
  register_version_change RenameOutdatedToStale
end
```

The namespace is declared once and becomes the relationship name and the prefix for query keys (`filter[run-stats.stale]`), so plugins can't collide with core or with each other. Their contributions are additive, they don't modify core's filters, sorts or default sort. The four rules are in the [plugins update](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/17).

### Safety net

A committed contract file, one entry per endpoint, fails CI on backwards-incompatible changes: a removed attribute, filter, sort or relationship, a changed resource type or relationship cardinality, a changed default sort, a lowered page limit. That failure is also the signal that a version change is needed. The generated documentation is committed as well, so a declaration change that isn't regenerated fails the build, and the documentation diff is part of the review. Specs validate live responses against the generated schemas.

## Decisions and trade-offs

Each of these is argued in the reference docs, the short version:

- We write the framework instead of using a gem. `jsonapi-resources` hasn't had a stable release since 2022 and got one commit in the last twelve months (its repository changed hands in March 2026), with Rails 8 issues still open. Graphiti is maintained and capable, but it brings its own resource, persistence and query layers, and makes every attribute filterable and sortable by default, which is something we'd rather not expose by default. What we need is narrower: rendering (jsonapi-serializer) and a keyset pagination engine (pagy), plus our own controller/resource layer. That's currently about 1,800 lines of framework code, plus 1,000 for the documentation generator (prototype, not production code). Comparison and details in [this post](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/1) and [api-modernization-exploration.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/api-modernization-exploration.md).
- Versions are dates, not major versions. No `/v2` cliff, no parallel code paths, no coordinated migration. Each breaking change is one dated step, and clients move when they choose. Design in [versioning-design.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/versioning-design.md).
- Plugins own their types and their version list. Their query keys are namespaced automatically, and their contributions are additive so core isn't affected by what a site installs. [plugins-design.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/plugins-design.md)
- The documentation is generated from the declarations. The only part written by hand is the introduction (authentication, versioning, pagination, errors). [api-docs-generation.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/api-docs-generation.md) · [resource-design.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/resource-design.md)

## Performance

Performance was measured during the exploration with two methods: HTTP throughput of the endpoints in a production-like environment and an in-process allocation and query-count model of the renderers. Against Graphiti this stack is leaner on both (flat and compound). Against Data Explorer's current AMS endpoint, it serves more requests per second, flat and compound too. The one place it doesn't win is allocations on compound documents, where AMS inlines associations in a different, flatter shape (so it's a reference point rather than a like-for-like comparison). What I take from those numbers is that this stack isn't a performance compromise, the choice itself rested on depending versus owning. Numbers are in the [first post](https://dev.discourse.org/t/modernizing-how-we-write-apis-in-discourse-a-json-api-experiment/186394/1) and [api-modernization-exploration.md](https://github.com/discourse/discourse/blob/loic/json-api-experiments/plugins/discourse-data-explorer/docs/api-modernization-exploration.md).

Cursor pagination removes the offset problem by design. Beyond that we control the whole chain (rendering, query building, pagination, version transforms), so if a specific endpoint needs optimization, we can do it where it's needed instead of working around a gem.

## Rollout

Following the project overview: build the infrastructure in core with one real endpoint (Data Explorer), then migrate a few self-contained areas (Data Explorer, chat) until the migration is documented well enough to be shared across the team, then convert the rest, prioritized by real customer usage (so probably topics/posts). The current API stays in place for now, both can serve at the same time as the new one is opt-in per request.

## Open questions

1. Where do the new endpoints live? A global `/api/...` namespace seems the logical choice, and that's what I'd go with, but it's probably easier to settle now than later.
2. What longevity should we advertise for a pinned version? Keeping an old pin isn't that expensive (a chain of small transforms), so it's less about our cost than about what integrators need to hear from us.
3. Where should the documentation live? The generated document can go through the existing docs.discourse.org pipeline as a second set of pages. The experience we'd want, something similar to Stripe's, may need its own site.

Please comment below, even (especially) if you disagree or feel I missed something :slight_smile:
