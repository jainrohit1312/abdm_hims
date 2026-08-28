-- ======================================================================
-- Seed Data: Default Admin User & Setup
-- ======================================================================

-- Create admin user in auth.users
-- CRITICAL: Use gen_salt('bf', 10) for cost factor 10 (not default 6).
-- Supabase GoTrue expects bcrypt with cost factor 10. Lower cost factors
-- will cause "Invalid email or password" errors during login.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, is_super_admin)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  'admin@himshospital.com',
  crypt('password123', gen_salt('bf', 10)),
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"role":"admin","first_name":"Admin","last_name":"User"}',
  now(),
  now(),
  '',
  '',
  '',
  '',
  false
);

-- Link admin user to users table (with hospital assignment)
INSERT INTO public.users (auth_id, hospital_id, first_name, last_name, email, role, is_active)
SELECT 
  auth.id,
  h.id,
  'Admin',
  'User',
  'admin@himshospital.com',
  'admin',
  true
FROM auth.users auth
CROSS JOIN public.hospitals h
WHERE auth.email = 'admin@himshospital.com'
  AND h.code = 'HIMS'
ON CONFLICT (email) DO NOTHING;