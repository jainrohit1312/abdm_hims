-- ======================================================================
-- Prescription full-head support (History / Vitals / Examination /
-- Diagnosis / Investigations / Advice / Follow-up)
--
-- prescriptions table ab sirf medicines nahi — poori prescription ka
-- structured clinical data ek JSONB column mein store karegi:
--
--   {
--     "chief_complaints": "...",
--     "hopi": "...",
--     "past_history": "...",
--     "personal_family_history": "...",
--     "drug_allergy": "...",
--     "examination": "...",
--     "diagnosis": "...",
--     "vitals": {"bp": "...", "pulse": "...", "temp": "...", "spo2": "...", "weight": "..."},
--     "investigations": {
--       "previous_findings": "...",
--       "blood": ["CBC", "LFT"],
--       "radiology": ["X-Ray Chest"]
--     },
--     "advice": "...",
--     "follow_up": "..."
--   }
--
-- Sirf wahi heads print honge jinke paas data hai; empty sections ke liye
-- JSONB mein key hi nahi dalte.
-- ======================================================================

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS clinical_notes JSONB DEFAULT '{}'::jsonb;

-- JSONB mein direct query karne ke liye GIN index (optional but helpful).
CREATE INDEX IF NOT EXISTS idx_prescriptions_clinical_notes
    ON prescriptions USING GIN (clinical_notes);
