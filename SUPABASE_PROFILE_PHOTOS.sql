-- Secure Messenger: private persistent profile photos (audit patch 6).
-- RUN IN SUPABASE SQL EDITOR AFTER SUPABASE_SETUP.sql.
-- Reuses public.secure_messenger_firebase_uid() from the original setup.
-- It does not change the chat-media bucket or bilateral media consent rules.
-- All Firebase-authenticated users can read profile photos (same as Firestore
-- profiles read rule). Only the owner can upload/delete their own photos.
-- Not a public bucket; do not put a service_role / secret key in Flutter.

begin;

insert into storage.buckets
  (id, name, public, file_size_limit, allowed_mime_types)
values
  ('profile-photos', 'profile-photos', false, 2097152,
   array['image/jpeg', 'image/png', 'image/webp']::text[])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists sm_profile_photo_insert on storage.objects;
drop policy if exists sm_profile_photo_read on storage.objects;
drop policy if exists sm_profile_photo_delete on storage.objects;

create policy sm_profile_photo_insert on storage.objects
for insert to anon, authenticated
with check (
  bucket_id = 'profile-photos'
  and (select public.secure_messenger_firebase_uid()) is not null
  and name ~ '^profiles/[^/]+/[0-9]{16,17}[.](jpg|jpeg|png|webp)$'
  and split_part(name, '/', 2) = (select public.secure_messenger_firebase_uid())
);

create policy sm_profile_photo_read on storage.objects
for select to anon, authenticated
using (
  bucket_id = 'profile-photos'
  and (select public.secure_messenger_firebase_uid()) is not null
  and name ~ '^profiles/[^/]+/[0-9]{16,17}[.](jpg|jpeg|png|webp)$'
);

create policy sm_profile_photo_delete on storage.objects
for delete to anon, authenticated
using (
  bucket_id = 'profile-photos'
  and (select public.secure_messenger_firebase_uid()) is not null
  and name ~ '^profiles/[^/]+/[0-9]{16,17}[.](jpg|jpeg|png|webp)$'
  and split_part(name, '/', 2) = (select public.secure_messenger_firebase_uid())
);

-- No UPDATE policy. Each updated picture uses a new unique object path.
commit;
