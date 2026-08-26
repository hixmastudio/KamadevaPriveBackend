-- ============================================================================
-- 0010 — Seed the five venues (design §3.1). Launching Cleanbite / Noh-Ra
-- later is flipping is_active — zero migrations.
-- ============================================================================

insert into venues (name, slug, type, is_active, launched_at) values
  ('Oso Lounge',        'oso',       'lounge',  true,  '2024-01-01'),
  ('Boom Boom Room',    'bbr',       'club',    true,  '2024-01-01'),
  ('Oxymor Concepts',   'oxymor',    'events',  true,  '2024-01-01'),
  ('Cleanbite Kitchen', 'cleanbite', 'kitchen', false, null),
  ('Noh-Ra Cabaret',    'nohra',     'cabaret', false, null)
on conflict (slug) do nothing;
