-- Fix signup error by ensuring all required columns exist and are populated
-- This handles the "Database error saving new user" which often occurs when
-- the trigger fails to populate required columns or columns are missing.

-- 1. Ensure profiles table has all necessary columns
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS username TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS credits NUMERIC DEFAULT 46;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS last_daily_bonus_at TIMESTAMPTZ;
-- 2. Update the handle_new_user trigger function to populate these columns
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  username text;
  full_name text;
  avatar_url text;
BEGIN
  -- Extract metadata from raw_user_meta_data
  -- Note: We use COALESCE to handle cases where metadata might be missing
  username := new.raw_user_meta_data->>'username';
  full_name := new.raw_user_meta_data->>'full_name';
  avatar_url := new.raw_user_meta_data->>'avatar_url';

  -- Fallback if username is null (use email prefix)
  IF username IS NULL THEN
    username := split_part(new.email, '@', 1);
  END IF;
  
  -- Fallback if full_name is null
  IF full_name IS NULL THEN
    full_name := username;
  END IF;

  INSERT INTO public.profiles (
    id, 
    email, 
    username, 
    full_name, 
    avatar_url, 
    credits, 
    last_daily_bonus_at
  )
  VALUES (
    new.id, 
    new.email, 
    username, 
    full_name, 
    avatar_url, 
    46, -- Default credits for new users
    NOW()
  )
  ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      username = COALESCE(EXCLUDED.username, public.profiles.username),
      full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
      avatar_url = COALESCE(EXCLUDED.avatar_url, public.profiles.avatar_url),
      credits = COALESCE(public.profiles.credits, EXCLUDED.credits);
  
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- 3. Ensure the trigger is correctly attached
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
