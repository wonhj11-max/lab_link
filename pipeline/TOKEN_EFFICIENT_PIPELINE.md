# Token-efficient publication pipeline

Updated 2026-09-26. The default path performs no model calls.

## Measured comparison

| Method | Verification value | Model-token use | Outcome on current official lists |
| --- | --- | ---: | --- |
| OpenAlex author discovery | Broad recall; not publication proof | 0 | Candidate queue for five labs; never sufficient alone for public approval |
| Per-paper browser/model review | Strong when publisher content is accessible | High and proportional to full-page text | Used for three enriched ESCML examples |
| Official HTML adapter + exact Crossref match | Strong base bibliography proof when title and faculty author both match | 0 | MEST 54/63 and AEML 43/68 matched; 34 held |

The third method is the default. A model is used only for held conflicts, abstract summaries, keyword extraction, explicit corresponding-author evidence that an adapter cannot encode, and IF evidence not exposed as structured official data.

## Flow and safety gates

1. Fetch a curated official Publications URL. No user-supplied URLs or redirects are accepted.
2. Extract year, title, linked DOI, official author string and journal using a versioned site adapter.
3. Resolve DOI through Crossref or require one unique exact normalized title match.
4. Require the professor in ordered Crossref authors, an in-range publication year, and exact official title equality.
5. Publish base bibliography through the service-only `publish_verified_bibliography` RPC in batches of at most 20. The RPC repeats the exact-match gates, writes ordered authors and an audit log, and never grants browser clients write access.
6. Keep failures as held checkpoint records. Do not spend model tokens automatically; process them in small exception batches.
7. Enrich summaries, keywords, author roles and year-specific IF independently. Missing enrichment never causes a fabricated value or a current-IF substitution.

## Scaling to new labs

Add a curated configuration plus a small deterministic adapter returning the common entry contract used by `scale-publications.mjs`. Run locally without `--publish`, inspect counts and held reasons, add parser fixtures, then enable the lab in the scheduled workflow. Prefer JSON APIs, embedded structured data and stable CSS selectors in that order. Cache by DOI/title hash and only refetch changed official pages.

Labs without a complete official publication page stay on discovery-only mode until a university repository or official profile provides paper-level evidence. ORCID and OpenAlex alone must not trigger publication.
