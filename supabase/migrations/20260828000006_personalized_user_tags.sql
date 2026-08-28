-- ======================================================================
-- HIMS - Personalized (AI-flavoured) User Tag System
--
-- Tags are stored PER USER (not per hospital) and PER FIELD CONTEXT
-- (patient, opd, ipd, compliance, ...) so suggestions are context-aware
-- and ordered by the user's own usage frequency.
--
-- Tables:
--   user_tags     -> the user's personal tag collection (master list)
--   entity_tags   -> which tags are applied to which record (link table)
--
-- The app shows "These tags are customized for you" and "Based on your
-- history..." suggestions. All RLS policies are user-scoped: a user can
-- only ever see or modify their OWN tags.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. USER TAGS (personal collection, one row per user+context+tag name)
--    usage_count drives the "order of usage frequency" in suggestions.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_tags (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    field_key VARCHAR(40) NOT NULL,
    name VARCHAR(120) NOT NULL,
    usage_count INTEGER NOT NULL DEFAULT 0,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Same tag name must stay unique per user + context (case-insensitive).
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_tags_unique
    ON user_tags (user_id, field_key, LOWER(name));

CREATE INDEX IF NOT EXISTS idx_user_tags_user_field
    ON user_tags (user_id, field_key);
CREATE INDEX IF NOT EXISTS idx_user_tags_usage
    ON user_tags (user_id, field_key, usage_count DESC, last_used_at DESC);

-- ----------------------------------------------------------------------
-- 2. ENTITY TAGS (links a tag to a record such as a patient or admission)
--    entity_type examples: patient | opd_registration | ipd_admission
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS entity_tags (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tag_id UUID NOT NULL REFERENCES user_tags(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    entity_type VARCHAR(40) NOT NULL,
    entity_id UUID NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- One tag can only be applied once to the same record by the same user.
CREATE UNIQUE INDEX IF NOT EXISTS idx_entity_tags_unique
    ON entity_tags (tag_id, entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_entity_tags_entity
    ON entity_tags (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_entity_tags_user
    ON entity_tags (user_id);

-- ----------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY — user-scoped (own tags only)
-- ----------------------------------------------------------------------
ALTER TABLE public.user_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entity_tags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_tags_select_own" ON public.user_tags;
CREATE POLICY "user_tags_select_own" ON public.user_tags
    FOR SELECT TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "user_tags_insert_own" ON public.user_tags;
CREATE POLICY "user_tags_insert_own" ON public.user_tags
    FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "user_tags_update_own" ON public.user_tags;
CREATE POLICY "user_tags_update_own" ON public.user_tags
    FOR UPDATE TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "user_tags_delete_own" ON public.user_tags;
CREATE POLICY "user_tags_delete_own" ON public.user_tags
    FOR DELETE TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "entity_tags_select_own" ON public.entity_tags;
CREATE POLICY "entity_tags_select_own" ON public.entity_tags
    FOR SELECT TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "entity_tags_insert_own" ON public.entity_tags;
CREATE POLICY "entity_tags_insert_own" ON public.entity_tags
    FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "entity_tags_update_own" ON public.entity_tags;
CREATE POLICY "entity_tags_update_own" ON public.entity_tags
    FOR UPDATE TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "entity_tags_delete_own" ON public.entity_tags;
CREATE POLICY "entity_tags_delete_own" ON public.entity_tags
    FOR DELETE TO authenticated
    USING (user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ----------------------------------------------------------------------
-- 4. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON user_tags TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON entity_tags TO authenticated, anon;
