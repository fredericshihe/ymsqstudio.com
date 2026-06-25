ALTER TABLE public.redeem_codes ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_redeem_codes_deleted_at ON public.redeem_codes (deleted_at);
