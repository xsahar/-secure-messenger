-- Secure Messenger: PRIVATE Supabase Storage for STANDARD-CHAT media only.
-- Run once in your SUPABASE project's SQL Editor, NOT in Firebase.
-- Firebase project ID: messenger-ef774
-- Before running: configure Supabase Authentication > Third-Party Auth > Firebase
-- with this Firebase project ID. Do not use a public bucket or a service_role key.
--
-- Why TO anon, authenticated? Firebase ID tokens do not include a Postgres
-- "role" claim by default; Supabase maps those VERIFIED Firebase tokens to
-- the anon DB role. These policies still REQUIRE a valid signed Firebase JWT
-- with our exact Firebase issuer/audience and a matching UID.
-- A bare public Supabase publishable key does NOT satisfy these policies.

insert into storage.buckets (
    id, name, public, file_size_limit, allowed_mime_types
) values (
    'chat-media', 'chat-media', false, 12582912,
    array[
        'image/jpeg', 'image/png', 'image/webp',
        'video/mp4', 'video/quicktime', 'audio/mp4'
    ]::text[]
)
on conflict (id) do update set
    public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Firebase UIDs are STRINGs, not UUIDs. Never use auth.uid() for these tokens.
-- This function returns NULL for all requests not issued by our Firebase
-- project; Supabase's third-party Auth integration verifies the JWT signature.
create or replace function public.secure_messenger_firebase_uid()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when auth.jwt()->>'iss' = 'https://securetoken.google.com/messenger-ef774'
     and auth.jwt()->>'aud' = 'messenger-ef774'
     and length(coalesce(auth.jwt()->>'sub', '')) between 1 and 128
    then auth.jwt()->>'sub'
    else null
  end;
$$;

-- Existing Firestore connection IDs are exactly uidA_uidB, sorted, with
-- no underscores in either UID. This prototype explicitly rejects underscore
-- characters inside UIDs rather than ambiguously parsing such IDs.
-- A Storage object key is:
--   connections/<firebase-connection-id>/<sender-uid>/<firestore-message-id>.<ext>
-- Access for recipients is based on the connection ID pair, not on querying
-- Firestore's accepted status from Supabase. Do not mistake this for complete
-- synchronization of Firebase contacts into Supabase.

DROP POLICY IF EXISTS "sm_media_upload" ON storage.objects;
DROP POLICY IF EXISTS "sm_media_read" ON storage.objects;
DROP POLICY IF EXISTS "sm_media_delete" ON storage.objects;

create policy "sm_media_upload"
on storage.objects
for insert
to anon, authenticated
with check (
    bucket_id = 'chat-media'
    and (select public.secure_messenger_firebase_uid()) is not null
    and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
    and split_part(name, '/', 3) = (select public.secure_messenger_firebase_uid())
    and (
        split_part(split_part(name, '/', 2), '_', 1) = (select public.secure_messenger_firebase_uid())
        or split_part(split_part(name, '/', 2), '_', 2) = (select public.secure_messenger_firebase_uid())
    )
);

create policy "sm_media_read"
on storage.objects
for select
to anon, authenticated
using (
    bucket_id = 'chat-media'
    and (select public.secure_messenger_firebase_uid()) is not null
    and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
    and (
        split_part(split_part(name, '/', 2), '_', 1) = (select public.secure_messenger_firebase_uid())
        or split_part(split_part(name, '/', 2), '_', 2) = (select public.secure_messenger_firebase_uid())
    )
);

create policy "sm_media_delete"
on storage.objects
for delete
to anon, authenticated
using (
    bucket_id = 'chat-media'
    and (select public.secure_messenger_firebase_uid()) is not null
    and name ~ '^connections/[^/_]+_[^/_]+/[^/]+/[A-Za-z0-9]{20}[.](jpg|jpeg|png|webp|mp4|mov|m4a)$'
    and split_part(name, '/', 3) = (select public.secure_messenger_firebase_uid())
);

-- No UPDATE policy: clients cannot overwrite existing media.
-- This script does NOT create any public-read policy.
