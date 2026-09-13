ALTER TABLE public.patients
    ADD COLUMN IF NOT EXISTS admission_type text,
    ADD COLUMN IF NOT EXISTS registration_method text;

NOTIFY pgrst, 'reload schema';