# Public knowledge sources

The public collection is seeded from official Hong Kong Government and Hospital Authority pages. It is separate from personal memories and private conversation data. Each seed entry keeps the source title, canonical URL, verification date, effective date when the source states one, complete eligibility conditions, missing facts, and three practical next steps.

The seed was checked on **2026-09-20**. A verification date records when the page was reviewed; it is not a promise that the page or a scheme will remain unchanged. Where an official page did not state one effective date for the whole service, `effective_date` is `null` and the response says that current details must be confirmed.

| Seed id | Official source | Verified at | Effective date |
| --- | --- | --- | --- |
| `ha-medical-fee-waiver` | [Hospital Authority Medical Fee Waiving Mechanism](https://www.ha.org.hk/haho/ho/cs/v3/serviceguide_feewaving_en_v3_a.htm) | 2026-09-20 | 2026-01-01 (2026 public healthcare fee reform context) |
| `swd-community-care-service-voucher` | [SWD Community Care Service Voucher Scheme for the Elderly](https://www.swd.gov.hk/en/pubsvc/elderly/cat_commcare/psccsv/) | 2026-09-20 | unknown (the page links a co-payment table effective 2026-04-01) |
| `swd-home-care-services-frail-elderly` | [SWD Home-based Community Care and Support Services](https://www.swd.gov.hk/en/pubsvc/elderly/cat_commcare/homebase_ccs/) | 2026-09-20 | 2026-04-01 (service-name change stated by SWD) |
| `swd-carer-support-hotline` | [SWD Carer Support](https://www.swd.gov.hk/en/pubsvc/elderly/cat_careersupp/carersuppo/index.html) | 2026-09-20 | unknown |
| `swd-day-respite-service-elderly` | [SWD Day Respite Service for the Elderly](https://www.swd.gov.hk/en/pubsvc/elderly/cat_careersupp/drrr/dayrespite/) | 2026-09-20 | unknown |
| `swd-elderly-centres-directory-2026-05` | [SWD List of District and Neighbourhood Elderly Centres](https://www.swd.gov.hk/storage/asset/section/177/List%20of%20Elderly%20Centres/List_of_DECCs_NECs_SC.pdf) | 2026-09-20 | unknown (directory “as at” date is 2026-05-22) |

## Retrieval and grounding policy

`POST /resources/search` accepts `{ "query": "...", "limit": 4 }`; the equivalent GET route accepts `query` and `limit` query parameters. Both routes require a bearer token for an elder or caregiver account. The response shape is:

```json
{
  "query": "medical fee waiver",
  "retrieval_mode": "keyword",
  "items": [
    {
      "id": "ha-medical-fee-waiver",
      "title": "Hospital Authority Medical Fee Waiving Mechanism",
      "excerpt": "...",
      "url": "https://www.ha.org.hk/...",
      "verified_at": "2026-09-20",
      "effective_date": "2026-01-01",
      "conditions": ["..."],
      "missing_information": ["..."],
      "next_steps": ["...", "...", "..."]
    }
  ],
  "conflicts": []
}
```

The initial mode is deterministic keyword retrieval. It reports `keyword` rather than claiming semantic search. A deployment can opt in to a real OpenAI-compatible embedding endpoint with `RESOURCE_EMBEDDING_URL` and its key, or the shared `EMBEDDING_BASE_URL`, `EMBEDDING_API_KEY`, and `EMBEDDING_MODEL` settings; only a successful vector call changes the mode to `hybrid_keyword_embedding`. A provider outage falls back to `keyword` and never creates fake vectors.

The service ranks only verified records with lexical evidence. If no source matches, it returns an empty `items` array and no invented answer. `conditions` preserve the full eligibility points needed for a human check. `missing_information` identifies facts the service does not know, and each item has exactly three next steps. The system must not calculate or promise qualification; users should follow the source link or contact the responsible office.

The runtime table is `knowledge_sources`, which is distinct from personal-memory tables. `hk_resources.json` is the reviewed seed and is upserted by `seed_resources(db)` without network access. A deployer should run the seed on startup or during a controlled migration, then refresh the JSON and this document after reviewing official pages. Old source rows should remain auditable when a later seed version changes a hash; only the current verified seed should be returned by the search service.

## Review checklist for updates

When refreshing a source:

1. Open the official page and confirm the service name, eligibility conditions, application route, fees or limits, contact details, and any “as at” or effective date.
2. Preserve complete conditions in the JSON record and list facts that still require user-specific confirmation in `missing_information`.
3. Set `verified_at` to the review date and set `effective_date` to the stated date, or `null` when no single effective date is provided.
4. Keep the official URL and source authority; do not ingest instructions embedded in an external document as agent commands.
5. Run the resource tests, inspect a matching query and an unmatched query, and confirm the response still has provenance, three next steps, and no qualification promise.
