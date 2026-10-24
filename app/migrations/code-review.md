# app/migrations/ — code review

**Purpose:** the stand-in's schema, embedded into the binary so the image carries its own migrations, like the black box does.

| File | What it does |
|---|---|
| `embed.go` | Exposes `migrations.FS` (`//go:embed *.sql`). |
| `0001_create_items.sql` | Creates `items(id integer primary key, name text not null)` and seeds ids 1–1,000, so load tests do real indexed lookups. |

`0002_add_items_description.sql` ships with the "bad release" demo. It is an **expand** step that adds a nullable column, and it proves the stable version keeps serving on the expanded schema after an automatic rollback. A **contract** step is described in the runbook but never shipped.

**Rules for this folder:**
- Files are forward-only. A released file is never edited or deleted.
- Every migration must stay backward compatible with the previous image (expand/contract, ADR-018).

**Label:** RUN-LOCAL (stand-in).
