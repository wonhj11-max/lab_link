# Official publication lists and journal-year IF

Updated 2026-09-26. User-authorized implementation and data workflow.

1. Read a lab's own Publications page, each requested year and pagination. Preserve each title, journal citation and DOI/publisher URL in `private.lab_publication_entries`. Listing year and website posting date are not automatically the final publication date. Preserve entries without a DOI and resolve them separately.
2. Read the linked publisher record. Check DOI, title, ordered authors, affiliations, publication date and article type. Store ordered authors in `paper_authors`; record first/co-first/corresponding flags only from explicit publisher evidence. Never publish OpenAlex authorship flags as verified.
3. Use the existing operator approval RPC to publish a verified candidate, with structured enrichment in the same SQL transaction. IF and summary availability are independent of bibliographic publication approval. Keep unavailable sources in the private index with a reason.
4. Reuse a journal by its verified identity/ISSN. `papers.journal_id` links to `journals.id`. `journal_metrics` stores one JIF record per `(journal_id,metric_type,metric_year)`. Enter official year-labelled JIF via the server-only `save_journal_impact_factor` RPC. Values without evidence stay null. Distinguish `metric_year` from `release_year`.
5. `journals.impact_factors` is an automatically synchronized JSON history for inspecting yearly values in the journals table. Do not manually edit this derived column. Add/update the normalized journal_metrics record via the RPC; the trigger synchronizes history.
6. `list_lab_publications` matches journal_id and `papers.year = journal_metrics.metric_year`. It never substitutes the current or latest available JIF. The frontend independently checks the year and exposes the JIF source. All ordered authors are available in a disclosure.
7. Verify the public RPC and the deployed lab page after writes; record per-paper and per-batch progress in private run/evidence records. Record source failures and remaining work accurately.

## Verified IF sources

- Nanomaterials: https://www.mdpi.com/journal/nanomaterials/history — 2022: 5.3; 2023: 4.4; 2024: 4.3; 2025: 4.8.
- Nature Communications: https://www.nature.com/ncomms/journal-impact — 2025: 18.1.

## Official ESCML source

http://escml.hanyang.ac.kr/sub/sub04_01.php?year=2026#contArea provides visible links to each year. The 2022–2026 pages yielded 114 linked entries (26, 30, 23, 24, 11 respectively). Some entries use publisher links without explicit DOI; preserve them. This is an observed website inventory, not a claim that every entry is independently verified or that the website is exhaustive.
