-- ─────────────────────────────────────────────────────────────────────────────
-- 0075 — the staff_welcome template
--
-- Its own migration, and that is not tidiness. ALTER TYPE ... ADD VALUE cannot
-- be used by anything in the same transaction that adds it, so a single file
-- adding the value and then writing a function that references it fails on
-- apply. Splitting is the documented way round it.
-- ─────────────────────────────────────────────────────────────────────────────
alter type email_template add value if not exists 'staff_welcome';
