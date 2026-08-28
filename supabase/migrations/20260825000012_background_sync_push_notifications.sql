-- ======================================================================
-- HIMS - Background Sync & Push Notification Service
-- ----------------------------------------------------------------------
-- 1. `notifications` table ensure karta hai (initial schema mein already
--    exist karti hai; yeh migration idempotent hai — purane DB par bhi
--    missing columns add ho jayenge).
-- 2. Naya `user_devices` table FCM device tokens store karne ke liye.
-- 3. Notifications + user_devices par hospital/user-scoped RLS policies.
--
-- Supabase Dashboard -> SQL Editor mein run karo.
-- Idempotent: baar-baar run karne par koi error nahi aayega.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. NOTIFICATIONS TABLE (ensure columns)
-- ----------------------------------------------------------------------
ALTER TABLE public.notifications
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS title VARCHAR(255) NOT NULL DEFAULT 'Notification',
    ADD COLUMN IF NOT EXISTS message TEXT,
    ADD COLUMN IF NOT EXISTS notification_type VARCHAR(50) NOT NULL DEFAULT 'info',
    ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS link_url TEXT,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW();

-- Fast lookups for the notifications list + unread badge.
CREATE INDEX IF NOT EXISTS idx_notifications_user
    ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_hospital
    ON public.notifications(hospital_id);
CREATE INDEX IF NOT EXISTS idx_notifications_read
    ON public.notifications(is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_type
    ON public.notifications(notification_type);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at
    ON public.notifications(created_at DESC);

-- ----------------------------------------------------------------------
-- 2. USER DEVICES (FCM token registration)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_devices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.users(id) ON DELETE CASCADE,
    fcm_token TEXT NOT NULL,
    platform VARCHAR(30),
    app_version VARCHAR(20),
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_devices_token
    ON public.user_devices(fcm_token);
CREATE INDEX IF NOT EXISTS idx_user_devices_user
    ON public.user_devices(user_id);
CREATE INDEX IF NOT EXISTS idx_user_devices_hospital
    ON public.user_devices(hospital_id);

-- ----------------------------------------------------------------------
-- 3. RLS — NOTIFICATIONS (hospital/user scoped)
-- ----------------------------------------------------------------------
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Purani open policy hata do (initial schema wali).
DROP POLICY IF EXISTS "Enable all access for authenticated users on notifications"
    ON public.notifications;

-- Idempotency: agar policies pehle se hain toh pehle drop karo.
DROP POLICY IF EXISTS "tenant_select_notifications" ON public.notifications;
DROP POLICY IF EXISTS "tenant_insert_notifications" ON public.notifications;
DROP POLICY IF EXISTS "tenant_update_notifications" ON public.notifications;
DROP POLICY IF EXISTS "tenant_delete_notifications" ON public.notifications;

-- Staff apne hospital ki notifications dekh sakta hai + apni personal rows.
CREATE POLICY "tenant_select_notifications"
    ON public.notifications
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
        OR hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

-- Hospital ke staff apne hospital ke liye notification rows bana sakte hain.
CREATE POLICY "tenant_insert_notifications"
    ON public.notifications
    FOR INSERT TO authenticated
    WITH CHECK (
        hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

-- User sirf apni notifications ko read/unread mark kar sakta hai.
CREATE POLICY "tenant_update_notifications"
    ON public.notifications
    FOR UPDATE TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    )
    WITH CHECK (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

CREATE POLICY "tenant_delete_notifications"
    ON public.notifications
    FOR DELETE TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

-- ----------------------------------------------------------------------
-- 4. RLS — USER DEVICES (apna device token hi manage karo)
-- ----------------------------------------------------------------------
ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;

-- Idempotency: agar policies pehle se hain toh pehle drop karo.
DROP POLICY IF EXISTS "tenant_select_user_devices" ON public.user_devices;
DROP POLICY IF EXISTS "tenant_insert_user_devices" ON public.user_devices;
DROP POLICY IF EXISTS "tenant_update_user_devices" ON public.user_devices;
DROP POLICY IF EXISTS "tenant_delete_user_devices" ON public.user_devices;

CREATE POLICY "tenant_select_user_devices"
    ON public.user_devices
    FOR SELECT TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
        OR hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

CREATE POLICY "tenant_insert_user_devices"
    ON public.user_devices
    FOR INSERT TO authenticated
    WITH CHECK (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
        AND hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

CREATE POLICY "tenant_update_user_devices"
    ON public.user_devices
    FOR UPDATE TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    )
    WITH CHECK (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

CREATE POLICY "tenant_delete_user_devices"
    ON public.user_devices
    FOR DELETE TO authenticated
    USING (
        user_id = (SELECT id FROM public.users WHERE auth_id = auth.uid() LIMIT 1)
    );

-- ----------------------------------------------------------------------
-- 5. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
    public.notifications, public.user_devices
    TO authenticated;
