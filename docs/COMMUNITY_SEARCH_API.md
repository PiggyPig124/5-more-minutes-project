# Community search API

The default application now registers the LCSD SmartPLAY public JSON adapter for recreation and sports activities. The fixed official snapshot is fetched on demand and cached locally for 10 minutes. District, topic, audience and user identity are never sent upstream. These are programme-date-filtered snapshots; registration status and places are not live. Legacy `community_listings` rows do not drive the search endpoints. HKCMIS and JCVTP adapters remain disabled pending reuse permission.

## Browse activities

`GET /community/activities?topic=table_tennis&area=Sha%20Tin&target_group=elderly&offset=0&limit=20`

All query parameters are optional. `topic` accepts `tailoring`, `sewing`, `cooking`, `gardening`, `teaching`, `knitting`, `woodworking`, `health`, `tai_chi`, `dance`, `table_tennis`, `badminton`, `swimming`, `fitness`, `yoga`, or `hiking`. `area` is an official Chinese or English district name up to 50 characters; Chinese labels work with or without 區. `target_group` is `all` (API default) or `elderly`; the Flutter screen defaults to elderly. `offset` is nonnegative and `limit` is 1–40 (default 20). Date and all criteria are filtered locally before pagination. Hong Kong calendar dates determine expiry; elderly suitability uses the official target-group field.

## Match a confirmed skill to volunteer listings

`GET /community/opportunities?skill_id=<confirmed-skill-id>`

SmartPLAY does not provide volunteer jobs: this route returns `sources_disabled` without fetching the sports snapshot. The existing authorization checks still require an authenticated elder, active memory consent, a confirmed owner-private skill, and its still-active source memory. Only a generic topic derived from the confirmed skill is used for local filtering; source requests never contain the skill text, memory, conversation, account identity, or home location. The route rechecks consent and the memory after retrieval.

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

## Legacy HTML adapters (disabled) and limits

- HKCMIS: `https://hkcmis.com/embed?unit_id=3` (community activity listings).
- Jockey Club Volunteer Together Platform: `https://www.jcvtplatform.hk/zh/volunteer-opportunities` (volunteer opportunities).

Only these exact HTTPS provider hosts and fixed listing paths are fetched. Redirects are rejected. Each request has a 6-second read timeout, a 3-second connect timeout, and an 8-second total cap, plus a 700 KB body cap, HTML content-type check, and 80-result cap. Pages are parsed as untrusted text; scripts and page instructions are never executed. Provider/network/parser failures are returned in source status and do not advance `checked_at`.


## Earlier status-only patch — 2026-10-04 (historical)

The existing `search_state` stays compatible. An optional `search_reason` now
distinguishes `sources_disabled`, `source_unavailable`, `parse_failed`,
`no_matches`, and `stale_cache`; a successful matching result has a null reason.
Per-source `error_kind` distinguishes connection/upstream failures from an
unreadable page. A cache fallback keeps the original successful check time.
The Flutter activity screen translates these reason codes and shows one notice,
instead of displaying raw backend English and a duplicate network warning.
Client request failures, invalid criteria (400/422), and backend service errors
(5xx) also have separate localized feedback.

No live provider was enabled by this patch. Zero configured providers make no
external requests and explicitly report that search is not enabled. The screen
offers user-initiated links to the two providers' own pages, clearly labeled as
external website entrances rather than search results. No district or private
query is appended to those links. Listings, dates, and places remain to be checked
on the original websites; no synthetic listings are substituted.

Source review: [JCVTP terms](https://www.jcvtplatform.hk/en/terms-conditions)
sections 3.3(e) and 10.1 restrict scraping/search through unsupported interfaces
and content reuse without written authorization. The [HKCMIS public activity
page](https://hkcmis.com/embed?unit_id=3) was accessible, but no affirmative
automated-reuse permission was established. [EventHK's government dataset
notice](https://data.gov.hk/en-data/dataset/hk-dpo-mobileapps-eventhk-information)
states that updates stopped on 8 June 2026, so it was not enabled as a current
activity feed. The existing [SWD STE directory](https://portal.csdi.gov.hk/geoportal/?datasetId=swd_rcd_1696994103126_1549)
is a service/contact directory; its portal did not expose full licensing metadata
to this read-only review. [SWD FAQ 11](https://www.swd.gov.hk/en/svcdesk/faqs/serelderly/)
explains contacting the local Support Team for the Elderly, not live event dates
or vacancies. Neither directory nor FAQ was turned into activity search results.

Verification uses synthetic HTTP transports, temporary/in-memory SQLite, and
widget tests in both Traditional Chinese and English. It does not fetch live
provider listings, accept new terms, send private data, restart user services,
or exercise a real external browser launch. This local patch is not pushed or
deployed, and earlier Web/APK artifacts do not contain it.

## SmartPLAY public JSON integration — 2026-10-04

Source: [official DATA.GOV.HK dataset](https://data.gov.hk/en-data/dataset/hk-lcsd-prog-smartplay-prog), [data dictionary](https://www.lcsd.gov.hk/datagovhk/prog/smartplay_prog_data_dictionary.pdf), and [government open-data terms](https://data.gov.hk/en/terms-and-conditions). The UI identifies HKSAR Government/LCSD ownership and DATA.GOV.HK as the source. No account, key, payment or interactive acceptance is used to read this public JSON.

Only `https://data.smartplay.lcsd.gov.hk/rest/cms/api/v1/publ/contents/open-data/activity-prog/file` is fetched, using a fixed GET with no user parameters. Redirects and environment proxies are disabled. Connect/read timeouts are 5/12 seconds, with elapsed time checked against 45 seconds on each raw chunk and after parsing; a blocking socket read is independently bounded by its timeout. Both received and decompressed bytes are capped at 20 MiB, with bounded gzip/deflate decoding. The snapshot is atomically validated (maximum 10,000 rows) before replacing the cache. A single-flight lock prevents duplicate concurrent downloads; failures cool down for 60 seconds. Fresh cache lasts 10 minutes; failed refresh may return a snapshot no older than 6 hours, explicitly marked `stale_cache`, preserving the original successful `checked_at`. Expired programmes are still removed at response time.

The response adds `total_count`, `offset`, `limit`, and `has_more`. Items optionally include `title_en`, `summary_en`, `organization_en`, `area_en`, `date_text_en`, `eligibility_en`, `availability_note_en`, `source_url_en`, and `source_name_en`. Source fees, minimum age and a finite maximum age are displayed; maximum age 199 is the dictionary's unspecified sentinel. Notes may be bounded strings or arrays of strings/nulls. No `PLACES_LEFT` or quota is shown as current availability.

Detail links retain validated original TC/EN fields, restricted to HTTPS `www.smartplay.lcsd.gov.hk/programme/detail` with the matching activity number and language. No booking URL is invented, `registration_url` remains null, and `verified` remains false. Users confirm eligibility, registration and places on the official detail page. Localized notices distinguish disabled sources, upstream failure, parsing failure, no matches, stale cache and client errors. Filter changes invalidate old pages and reset pagination; a failed later page keeps the existing results for retry.

The earlier status-only validation and artifact note above describes its historical checkpoint. This integration's final full-regression, real-public-data browser and rebuilt artifact evidence is recorded separately in the local SmartPLAY acceptance receipt; it is not pushed, deployed or installed.
