ALTER TABLE patients 
ADD COLUMN admission_type TEXT DEFAULT 'OPD',
ADD COLUMN registration_method TEXT DEFAULT 'Direct';