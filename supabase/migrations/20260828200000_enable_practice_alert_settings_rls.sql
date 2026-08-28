BEGIN;

-- This singleton table is exposed through PostgREST so Realtime can deliver
-- grade-scope changes to the room dashboard. Keep that read path available,
-- but require all writes to go through save_practice_alert_settings().
ALTER TABLE public.practice_alert_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS practice_alert_settings_read
  ON public.practice_alert_settings;

CREATE POLICY practice_alert_settings_read
  ON public.practice_alert_settings
  FOR SELECT
  TO anon, authenticated
  USING (singleton IS TRUE);

REVOKE ALL ON TABLE public.practice_alert_settings FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.practice_alert_settings
  FROM anon, authenticated;
GRANT SELECT ON TABLE public.practice_alert_settings TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
