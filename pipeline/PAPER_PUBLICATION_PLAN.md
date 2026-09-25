# Paper publication implementation plan

The executable contract is `PAPER_PUBLICATION_GUIDELINES.md`. Implementation is additive: migration `202609250007` introduces structured authors, journal-year JIF, keywords, verified summaries, private evidence/runs, and `list_lab_publications`. The public application reads only the RPC; ordinary users lose queue/vote RPC access. The existing paper/link tables and audit history remain intact.

Frontend acceptance: the lab paper tab renders stable newest-first cards with title, journal/year, first and corresponding authors, year-labelled JIF status, DOI, verified keywords, and an accessible stored-summary disclosure. Missing values are explicit. `/paper-review` redirects to research browsing and the navigation no longer asks users to review.

Rollout: test/build locally; apply migration; read back function and grants; audit/enrich approved records with official institutional and publisher evidence; deploy; verify an anonymous production lab page. Investigation proceeds in batches of at most ten with checkpoints under `work/paper-publication` and private DB run/evidence records.
