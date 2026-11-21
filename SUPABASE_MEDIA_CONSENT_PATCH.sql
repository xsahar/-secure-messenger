-- Secure Messenger: media-authorization hardening for Supabase Free
-- Intended for the project that already ran SUPABASE_SETUP.sql.
-- Before running, replace Flutter lib/chat_screen.dart and stop both sessions.
-- After running, BOTH accounts must reopen the accepted chat ONCE before media
-- previously uploaded can be downloaded. All existing files remain in storage.
--
-- This is bilateral authenticated consent. It does NOT synchronize the current
-- Firestore connection status. A production architecture needs a trusted
-- server-side mirror and revocation when a connection is removed/blocked.
-- Do not use a service_role/secret key in the mobile app.

begin;

-- Separate consent row per account, protected by verified Firebase JWT.
create table if not exists public.media_consents (
  connection_id text not null,
  uid text not null,
  created_at timestamptz not null default now(),
  primary key (connection_id, uid),
  constraint sm_media_valid_connection_id
    check (connection_id ~ '^[^/_]+_[^/_]+$'),
  constraint sm_media_uid_is_member
    check (uid = split_part(connection_id, '_', 1)
       or uid = split_part(connection_id, '_', 2))
);

alter table public.media_consents enable row level security;

-- Firebase third-party tokens usually resolve as the `anon` Postgres role.
-- Restrict every access with a validated Firebase JWT check nevertheless.
revoke all on public.media_consents from public;
grant select, insert on public.media_consents to anon, authenticated;

drop policy if exists sm_media_consents_read_own on public.media_consents;
drop policy if exists sm_media_consents_insert_own on public.media_consents;

create policy sm_media_consents_read_own
on public.media_consents
for select to anon, authenticated
using (
  uid = (select public.secure_messenger_firebase_uid())
);

create policy sm_media_consents_insert_own
on public.media_consents
for insert to anon, authenticated
with check (
  uid = (select public.secure_messenger_firebase_uid())
  and (select public.secure_messenger_firebase_uid()) is not null
);

-- No client UPDATE or DELETE policies for consent records in this prototype.
-- This avoids spoofing the other account or silently overwriting approvals.

-- This is SECURITY DEFINER only so Storage RLS can see both consent rows
-- while direct clients can read ONLY their own records.
-- Caller is still REQUIRED to have a verified Firebase identity and be one
-- of the two named participants in the canonical connection ID.
create or replace function public.sm_media_pair_consented(p_connection_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    p_connection_id ~ '^[^/_]+_[^/_]+$'
    and public.secure_messenger_firebase_uid() is not null
    and public.secure_messenger_firebase_uid() in (
      split_part(p_connection_id, '_', 1),
      split_part(p_connection_id, '_', 2)
    )
    and exists (
      select 1 from public.media_consents c
      where c.connection_id = p_connection_id
        and c.uid = split_part(p_connection_id, '_', 1)
    )
    and exists (
      select 1 from public.media_consents c
      where c.connection_id = p_connection_id
        and c.uid = split_part(p_connection_id, '_', 2)
    ),
    false
  );
$$;

revoke all on function public.sm_media_pair_consented(text) from public;
grant execute on function public.sm_media_pair_consented(text)
  to anon, authenticated;

-- Replace ONLY the three original media policies. The bucket stays PRIVATE.
drop policy if exists "sm_media_upload" on storage.objects;
drop policy if exists "sm_media_read" on storage.objects;
drop policy if exists "sm_media_delete" on storage.objects;

create policy "sm_media_upload" on storage.objects
for insert to anon, authenticated
with check (
  bucket_id = 'chat-media'
  and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
  and split_part(name, '/', 3) = (select public.secure_messenger_firebase_uid())
  and (select public.sm_media_pair_consented(split_part(name, '/', 2)))
);

create policy "sm_media_read" on storage.objects
for select to anon, authenticated
using (
  bucket_id = 'chat-media'
  and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
  and (select public.sm_media_pair_consented(split_part(name, '/', 2)))
);

create policy "sm_media_delete" on storage.objects
for delete to anon, authenticated
using (
  bucket_id = 'chat-media'
  and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
  and split_part(name, '/', 3) = (select public.secure_messenger_firebase_uid())
  and (select public.sm_media_pair_consented(split_part(name, '/', 2)))
);

-- No UPDATE permission: file overwriting remains forbidden.
commit;
