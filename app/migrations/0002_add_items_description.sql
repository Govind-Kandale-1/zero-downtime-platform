-- 0002: EXPAND step (backward compatible). Adds a nullable column the previous
-- version simply ignores, so rolling the image back after this migration is
-- safe. Ships with the "bad release" demo to prove exactly that.
ALTER TABLE items ADD COLUMN IF NOT EXISTS description text NULL;
