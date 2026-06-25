-- Bootstrap default admin account
UPDATE public.profiles
SET is_admin = true
WHERE username = 'fredericshihe';
