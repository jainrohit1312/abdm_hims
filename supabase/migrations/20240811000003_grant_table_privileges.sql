-- ======================================================================
-- Grant table privileges to authenticated and anon roles
-- Required because newer Supabase versions no longer auto-expose
-- tables in the public schema via the Data API.
-- ======================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated, anon;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated, anon;