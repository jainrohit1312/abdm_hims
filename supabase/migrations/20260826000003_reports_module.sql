-- ======================================================================
-- HIMS - Reports Module (generated analytics reports)
--
-- Table:
--   reports -> generated reports with JSONB data/summary, DeepSeek AI
--              summary, file_url and status tracking.
--
-- report_type: consultation | patient | counseling |
--              doctor_performance | revenue | followup
-- status:      ready | generating | failed
-- file_format: pdf | xlsx | xls | csv
--
-- Flutter integration (lib/services/database_service.dart):
--   getReports()  -> select('*, users(name)') order created_at desc
--   getReportById -> select by id
-- Isliye `generated_by` FK users(id) se resolve hota hai aur `users`
-- table par SELECT grant/policy pehle se available hai.
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- Idempotent hai — baar baar run kar sakte hain.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. TABLE
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    report_type VARCHAR(50) NOT NULL DEFAULT 'general'
        CONSTRAINT chk_reports_report_type CHECK (
            report_type IN (
                'consultation',
                'patient',
                'counseling',
                'doctor_performance',
                'revenue',
                'followup',
                'general'
            )
        ),
    title VARCHAR(255) NOT NULL,
    date_from DATE,
    date_to DATE,
    filters JSONB NOT NULL DEFAULT '{}'::jsonb,
    generated_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    data JSONB NOT NULL DEFAULT '[]'::jsonb,
    summary JSONB NOT NULL DEFAULT '{}'::jsonb,
    ai_summary TEXT,
    file_url TEXT,
    file_format VARCHAR(10) NOT NULL DEFAULT 'pdf'
        CONSTRAINT chk_reports_file_format CHECK (
            file_format IN ('pdf', 'xlsx', 'xls', 'csv')
        ),
    status VARCHAR(20) NOT NULL DEFAULT 'generating'
        CONSTRAINT chk_reports_status CHECK (
            status IN ('ready', 'generating', 'failed')
        ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_reports_date_range CHECK (
        date_from IS NULL OR date_to IS NULL OR date_from <= date_to
    )
);

COMMENT ON TABLE public.reports IS
    'Generated analytics reports (consultation, patient, counseling, doctor performance, revenue, followup).';
COMMENT ON COLUMN public.reports.data IS
    'Detailed report rows/table data (JSONB, usually a list of objects).';
COMMENT ON COLUMN public.reports.summary IS
    'Summary statistics as key/value pairs (JSONB, rendered as stat cards).';
COMMENT ON COLUMN public.reports.ai_summary IS
    'AI generated narrative summary (DeepSeek).';

-- ----------------------------------------------------------------------
-- 2. INDEXES
-- ----------------------------------------------------------------------
-- Main list query: WHERE hospital_id = ? ORDER BY created_at DESC
CREATE INDEX IF NOT EXISTS idx_reports_hospital_created
    ON public.reports(hospital_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reports_type
    ON public.reports(report_type);

CREATE INDEX IF NOT EXISTS idx_reports_status
    ON public.reports(status);

CREATE INDEX IF NOT EXISTS idx_reports_generated_by
    ON public.reports(generated_by);

-- JSONB summary/filters filtering (future analytics queries)
CREATE INDEX IF NOT EXISTS idx_reports_data_gin
    ON public.reports USING GIN (data);

CREATE INDEX IF NOT EXISTS idx_reports_summary_gin
    ON public.reports USING GIN (summary);

-- ----------------------------------------------------------------------
-- 3. updated_at AUTO TRIGGER
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_reports_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_reports_updated_at ON public.reports;
CREATE TRIGGER trg_reports_updated_at
    BEFORE UPDATE ON public.reports
    FOR EACH ROW EXECUTE FUNCTION public.set_reports_updated_at();

-- ----------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (multi-tenant isolation)
--    Har hospital sirf apne reports dekh/change kar sakta hai.
-- ----------------------------------------------------------------------
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_all_reports" ON public.reports;
CREATE POLICY "tenant_all_reports" ON public.reports
    FOR ALL TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ))
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

-- ----------------------------------------------------------------------
-- 5. GRANTS (newer Supabase versions default-deny public tables)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.reports TO authenticated;
