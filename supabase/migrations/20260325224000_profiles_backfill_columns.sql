-- Backfill columns for existing profiles table in old projects.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS username text,
  ADD COLUMN IF NOT EXISTS access_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
-- NOTE: skip unique index here because legacy projects may already contain duplicate usernames.;
