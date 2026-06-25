-- Seed initial redeem codes (idempotent)
INSERT INTO public.redeem_codes (code, plan, max_uses, active)
VALUES
  ('MB-DAY-2026', 'day', 100, true),
  ('MB-WEEK-2026', 'week', 100, true),
  ('MB-MONTH-2026', 'month', 100, true)
ON CONFLICT (code) DO NOTHING;
