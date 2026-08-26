-- ============================================================================
-- 0056 — Keep the door working for tablets still running yesterday's code.
--
-- 0055 removed p_instagram from register_guest. The database changed the moment
-- it was applied; the browsers did not. A venue tablet holding a cached bundle
-- kept sending the old argument list and got
--
--     Could not find the function public.register_guest(..., p_instagram, ...)
--     in the schema cache
--
-- at the point of registering a guest who was standing at the door. That is my
-- error, and the lesson is not subtle: a signature is an interface, and clients
-- in the field do not redeploy when the database does. The change should have
-- gone out in two steps — accept both, ship the frontend, then drop the old one
-- — rather than one.
--
-- This restores the old signature as a thin shim that forwards to the current
-- function and discards the handle, so a stale tablet registers guests
-- correctly (card, consents and all) while quietly no longer storing an
-- Instagram handle for Privé members, which was the point of 0055.
--
-- WHY p_instagram HAS NO DEFAULT HERE, which looks odd next to the others:
-- PostgREST picks an overload by the exact set of argument names in the request.
-- If this shim defaulted p_instagram, a NEW client sending the eight current
-- arguments would match both functions and the call would fail as ambiguous —
-- trading a broken old client for a broken new one. Required, it can only match
-- a request that actually sends a handle, so each client resolves to exactly
-- one function.
--
-- THIS IS TEMPORARY. Once the venue tablets have been reloaded — confirm by
-- watching for calls carrying p_instagram — drop it:
--
--   drop function register_guest(text, text, text, uuid, text, boolean,
--                                consent_channel, text, date);
-- ============================================================================

create or replace function register_guest(
  p_phone             text,
  p_full_name         text,
  p_email             text,
  p_venue_id          uuid,
  p_instagram         text,                      -- accepted, deliberately unused
  p_consent_marketing boolean default false,
  p_channel           consent_channel default 'door_tablet',
  p_gender            text default null,
  p_date_of_birth     date default null
)
returns members
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
begin
  -- p_instagram is accepted and dropped on the floor. Privé membership no
  -- longer records a handle (0055); Muse does, through muse_initiate.
  return register_guest(
    p_phone             => p_phone,
    p_full_name         => p_full_name,
    p_email             => p_email,
    p_venue_id          => p_venue_id,
    p_consent_marketing => p_consent_marketing,
    p_channel           => p_channel,
    p_gender            => p_gender,
    p_date_of_birth     => p_date_of_birth
  );
end;
$$;

comment on function register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date) is
  'DEPRECATED compatibility shim for clients cached before 0055 removed
   p_instagram. Forwards to the current signature and ignores the handle.
   Remove once no caller sends p_instagram.';

revoke execute on function register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date) from public, anon;
grant  execute on function register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date) to authenticated;
