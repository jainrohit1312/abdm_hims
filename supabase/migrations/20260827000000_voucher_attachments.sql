-- ======================================================================
-- HIMS - Voucher Attachments
--
-- Adds a JSONB `attachments` column to the vouchers table so each voucher
-- can store a list of uploaded supporting documents (bills, AMC documents,
-- receipts, etc.).
--
-- Each attachment is stored as a JSON object:
--   { "name": "bill.pdf", "url": "https://...", "size": 12345 }
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- The actual files are uploaded to the existing `hims-storage` bucket by
-- the Flutter app (see StorageService.uploadBytes).
-- ======================================================================

ALTER TABLE vouchers
    ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'::jsonb;
