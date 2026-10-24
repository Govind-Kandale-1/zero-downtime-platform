-- 0001: the table the stand-in API reads, seeded with 1,000 rows so load tests
-- hit real indexed lookups.
CREATE TABLE items (
    id   integer PRIMARY KEY,
    name text    NOT NULL
);

INSERT INTO items (id, name)
SELECT g, 'item-' || g
FROM generate_series(1, 1000) AS g;
