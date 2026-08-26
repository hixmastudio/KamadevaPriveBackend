-- ============================================================================
-- 0037 — Menu categories for the shop.
--
-- catalog_items held only name, description and price, so the member shop could
-- render nothing but a flat list. That was survivable with five placeholder
-- items; the real menus are ~290 across Oso and Boom Boom Room, and a flat list
-- of 290 drinks is unusable on a phone at 11pm.
--
-- Adds the two columns needed to present a menu the way a menu is actually
-- read: a category ("Classic Cocktails", "Red Wines", "Champagnes") and an
-- explicit order, because menus have a deliberate sequence — cocktails before
-- spirits, starters before mains — that neither alphabetical nor price order
-- reproduces.
--
-- Nothing else changes: RLS, place_collect_order and the order tables are
-- untouched, so existing orders and the staff Collect desk carry on as they are.
-- ============================================================================

alter table catalog_items
  add column if not exists category   text,
  add column if not exists sort_order int not null default 0;

-- The shop reads by venue, then category, then the menu's own order.
create index if not exists catalog_items_menu_idx
  on catalog_items (venue_id, category, sort_order)
  where is_active;

comment on column catalog_items.category is
  'Menu section as printed — e.g. Classic Cocktails, Red Wines, Starters & Appetizers.';
comment on column catalog_items.sort_order is
  'Position within the category, following the printed menu rather than name or price.';
