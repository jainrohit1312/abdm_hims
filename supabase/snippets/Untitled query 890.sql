INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
VALUES (
  'admin@himshospital.com',
  crypt('password123', gen_salt('bf')),
  now(),
  '{"provider":"email"}',
  '{"role":"admin"}'
);