ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;
ALTER TABLE public.redeem_codes
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.profiles (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_is_admin ON public.profiles (is_admin);
CREATE INDEX IF NOT EXISTS idx_redeem_codes_created_by ON public.redeem_codes (created_by);
