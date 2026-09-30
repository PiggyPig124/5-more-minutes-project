# Community search API

Community source adapters can fetch provider pages on request and cache results in process for up to 15 minutes, but the default application configures no live providers while reuse permission remains unconfirmed. It returns an unavailable state and no listings. The cache contains source-page results only; it does not make event availability current. Legacy `community_listings` rows do not drive the search endpoints.

## Browse activities

`GET /community/activities?topic=cooking&area=Wan%20Chai`

Both query parameters are optional. `topic` is one of `tailoring`, `sewing`, `cooking`, `gardening`, `teaching`, `knitting`, `woodworking`, or `health`; `area` is a plain district name up to 50 characters. Filtering happens locally after the fixed provider pages are retrieved. No user text is sent to those sites.

## Match a confirmed skill to volunteer listings

`GET /community/opportunities?skill_id=<confirmed-skill-id>`

Requires an authenticated elder, active memory consent, a confirmed owner-private skill, and its still-active source memory. Only a generic topic derived from the confirmed skill is used for local filtering; source requests never contain the skill text, memory, conversation, account identity, or home location. The route rechecks consent and the memory after retrieval.

## Response

Both endpoints return:

```json
{
  "items": [],
  "no_results": true,
  "message": "The provider pages were searched, but no current matching listings were found.",
  "search_state": "live",
  "checked_at": "2026-09-27T00:00:00Z",
  "requested_at": "2026-09-27T00:00:01Z",
  "sources": [{"name": "Provider", "url": "https://example.org/", "state": "live", "checked_at": "2026-09-27T00:00:00Z", "error": null}]
}
```

`search_state` and per-source `state` are `live`, `cache`, or `unavailable`. `checked_at` is the time of the most recent successful provider retrieval and is `null` when none succeeded; `requested_at` is the current request time. A cache fallback keeps its original `checked_at` and includes an `error` on the failed source. `message` distinguishes searched/no-match, cache/no-match, and unavailable sources.

Each item has the ordinary activity fields plus `date_text`, `availability_note`, and `verified: false`. Dates come from the source card; expired rows are dropped. Results explicitly say that listing does not guarantee a place, eligibility, or continued availability; users must check the provider page before attending or applying.

## Chat discovery

An explicit request to find activities, classes, groups, events, or volunteering in authenticated or guest chat runs the same bounded search. The assistant message includes `community_sources`, `community_search_state`, `community_search_checked_at`, and up to eight `community_results`. These fields are omitted when no community search was requested. Guest replies expose the same fields at the response top level.

## Providers and limits

- HKCMIS: `https://hkcmis.com/embed?unit_id=3` (community activity listings).
- Jockey Club Volunteer Together Platform: `https://www.jcvtplatform.hk/zh/volunteer-opportunities` (volunteer opportunities).

Only these exact HTTPS provider hosts and fixed listing paths are fetched. Redirects are rejected. Each request has a 6-second read timeout, a 3-second connect timeout, and an 8-second total cap, plus a 700 KB body cap, HTML content-type check, and 80-result cap. Pages are parsed as untrusted text; scripts and page instructions are never executed. Provider/network/parser failures are returned in source status and do not advance `checked_at`.
