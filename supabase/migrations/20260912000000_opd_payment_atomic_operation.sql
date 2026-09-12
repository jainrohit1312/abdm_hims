-- ======================================================================
-- HIMS - Atomic OPD payment operation (server-side transaction + receipts)
-- ----------------------------------------------------------------------
-- PROBLEM
--   The offline OPD payment used to be uploaded as four independent PostgREST
--   writes (opd_registrations UPDATE, billing INSERT, billing_items INSERT,
--   payment_logs INSERT). PostgREST cannot span a transaction, so a failure
--   after the first write left the cloud with a partially applied accounting
--   operation: a paid visit without a bill, a bill without its payment, or a
--   duplicated collection on retry.
--
-- SOLUTION
--   One SECURITY DEFINER function that applies the COMPLETE accounting
--   operation inside a single transaction, together with a durable
--   server-side receipt that makes replays idempotent:
--
--     * hims_operation_receipts  — one row per (operation_id), holding the
--       canonical request payload and the committed result. Written in the
--       SAME transaction as the accounting rows, so a receipt can never
--       describe an uncommitted operation.
--     * hims_apply_opd_payment   — validates and applies the operation.
--
-- GUARANTEES
--   * Atomic: OPD payment transition + billing + billing_items + payment_logs
--     + billing_audit + receipt commit together, or none of them do.
--   * Idempotent: same operation_id + same canonical payload returns the
--     original committed result (never re-charges).
--   * Explicit conflict: same operation_id with a different payload raises
--     `hims_opd_payment_conflict` instead of silently succeeding.
--   * Concurrent retries cannot double-collect: the receipt INSERT claims the
--     operation_id under the primary key, so a concurrent duplicate blocks on
--     that key and then observes the committed result.
--   * Authorization from the authenticated user only (auth.uid() ->
--     public.users). Client-supplied hospital_id/created_by are never trusted.
--   * Every referenced patient / OPD visit / bill is verified to belong to the
--     authenticated hospital.
--
-- SCOPE: additive. The existing online OPD slip path
-- (DatabaseService.generateOPDSlip -> _syncOpdSlipToBilling) is untouched, and
-- no existing trigger is replaced, so online billing behaviour is preserved.
--
-- Idempotent — safe to run more than once.
--
-- WARNING: production migrations must be reviewed and approved before they are
-- applied. This file is a proposal, not an executed production change.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. Durable server-side operation receipts (idempotency + replay ledger)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hims_operation_receipts (
    operation_id        UUID PRIMARY KEY,
    hospital_id         UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    operation_type      TEXT NOT NULL,
    device_id           TEXT,
    canonical_payload   JSONB NOT NULL,
    result              JSONB NOT NULL DEFAULT '{}'::jsonb,
    operation_record_id UUID,
    created_by          UUID REFERENCES public.users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_operation_receipts_hospital
    ON public.hims_operation_receipts(hospital_id, created_at DESC);

ALTER TABLE public.hims_operation_receipts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "hospital-scoped operation receipts read"
    ON public.hims_operation_receipts;
CREATE POLICY "hospital-scoped operation receipts read"
    ON public.hims_operation_receipts FOR SELECT TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- Clients may READ their own receipts but never write them: a forged receipt
-- would let a client suppress a legitimate operation. Writes happen only
-- inside the SECURITY DEFINER function below.
REVOKE ALL ON public.hims_operation_receipts FROM anon, authenticated;
GRANT SELECT ON public.hims_operation_receipts TO authenticated;

-- ----------------------------------------------------------------------
-- 2. The atomic OPD payment operation
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hims_apply_opd_payment(
    p_operation_id        UUID,
    p_device_id           TEXT,
    p_opd_registration_id UUID,
    p_patient_id          UUID,
    p_consultation_fee    NUMERIC,
    p_discount_amount     NUMERIC,
    p_payment_amount      NUMERIC,
    p_payment_mode        TEXT,
    p_bill_id             UUID,
    p_bill_offline_id     UUID,
    p_bill_number         TEXT,
    p_bill_item_id        UUID,
    p_payment_log_id      UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
-- Pinned, fully-qualified search path: the function runs with owner rights, so
-- it must not be steerable through a caller-controlled schema.
SET search_path = public
AS $func$
DECLARE
    v_hospital_id      UUID;
    v_user_id          UUID;
    v_canonical        JSONB;
    v_receipt          public.hims_operation_receipts%ROWTYPE;
    v_opd              public.opd_registrations%ROWTYPE;
    v_bill             public.billing%ROWTYPE;
    v_existing_bill    public.billing%ROWTYPE;
    v_bill_exists      BOOLEAN := FALSE;
    v_payment_exists   BOOLEAN := FALSE;
    v_total            NUMERIC(12,2);
    v_discount         NUMERIC(12,2);
    v_net              NUMERIC(12,2);
    v_paid             NUMERIC(12,2);
    v_balance          NUMERIC(12,2);
    v_status           TEXT;
    v_bill_status      TEXT;
    v_discount_pct     NUMERIC(5,2) := 0;
    v_mode             TEXT;
    v_bill_item_id     UUID;
    v_payment_log_id   UUID;
    v_bill_date        DATE;
    v_now              TIMESTAMPTZ := NOW();
    v_result           JSONB;
    v_claimed          BOOLEAN := FALSE;
BEGIN
    -- ----------------------------------------------------------------
    -- 2.1 Authorization — derived from the authenticated user ONLY.
    -- ----------------------------------------------------------------
    IF p_operation_id IS NULL THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: operation id is required'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_opd_registration_id IS NULL OR p_patient_id IS NULL THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: opd visit and patient are required'
            USING ERRCODE = 'P0001';
    END IF;
    IF p_bill_id IS NULL OR p_bill_number IS NULL OR btrim(p_bill_number) = '' THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: bill id and bill number are required'
            USING ERRCODE = 'P0001';
    END IF;

    v_hospital_id := public.current_user_hospital_id();
    IF v_hospital_id IS NULL THEN
        RAISE EXCEPTION 'hims_opd_payment_forbidden: no hospital scope for the authenticated user'
            USING ERRCODE = '42501';
    END IF;

    SELECT u.id INTO v_user_id
      FROM public.users u
     WHERE u.auth_id = auth.uid()
     LIMIT 1;
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'hims_opd_payment_forbidden: no active user record for the authenticated subject'
            USING ERRCODE = '42501';
    END IF;

    -- ----------------------------------------------------------------
    -- 2.2 Canonical payload (the identity of this operation).
    --     Derived from validated, normalised values — never from a
    --     client-supplied canonical string.
    -- ----------------------------------------------------------------
    v_canonical := jsonb_build_object(
        'opd_registration_id', p_opd_registration_id,
        'patient_id', p_patient_id,
        'consultation_fee', round(coalesce(p_consultation_fee, 0), 2),
        'discount_amount', round(coalesce(p_discount_amount, 0), 2),
        'payment_amount', round(coalesce(p_payment_amount, 0), 2),
        'payment_mode', lower(btrim(coalesce(p_payment_mode, ''))),
        'bill_id', p_bill_id,
        'bill_offline_id', p_bill_offline_id,
        'bill_number', btrim(p_bill_number),
        'bill_item_id', p_bill_item_id,
        'payment_log_id', p_payment_log_id
    );

    -- ----------------------------------------------------------------
    -- 2.3 Claim the operation id. The receipt is inserted FIRST, in the
    --     same transaction as the accounting rows, so:
    --       * a rolled-back operation leaves no receipt (a retry works);
    --       * a committed operation always has a complete receipt;
    --       * a concurrent duplicate blocks on the primary key and then
    --         reads the committed result instead of double-collecting.
    -- ----------------------------------------------------------------
    INSERT INTO public.hims_operation_receipts (
        operation_id, hospital_id, operation_type, device_id,
        canonical_payload, result, created_by
    ) VALUES (
        p_operation_id, v_hospital_id, 'opd_payment', p_device_id,
        v_canonical, '{}'::jsonb, v_user_id
    )
    ON CONFLICT (operation_id) DO NOTHING;
    v_claimed := FOUND;

    IF NOT v_claimed THEN
        SELECT * INTO v_receipt
          FROM public.hims_operation_receipts
         WHERE operation_id = p_operation_id;

        IF v_receipt.hospital_id IS DISTINCT FROM v_hospital_id THEN
            RAISE EXCEPTION 'hims_opd_payment_forbidden: operation % belongs to another hospital', p_operation_id
                USING ERRCODE = '42501';
        END IF;
        IF v_receipt.canonical_payload IS DISTINCT FROM v_canonical THEN
            RAISE EXCEPTION 'hims_opd_payment_conflict: operation % was already applied with a different payload', p_operation_id
                USING ERRCODE = 'P0001';
        END IF;
        IF v_receipt.result IS NULL OR v_receipt.result = '{}'::jsonb THEN
            -- Should be unreachable: a receipt is only ever committed with its
            -- result. Refuse to guess instead of reporting a false success.
            RAISE EXCEPTION 'hims_opd_payment_conflict: operation % exists without a finalised receipt', p_operation_id
                USING ERRCODE = 'P0001';
        END IF;

        -- Exact replay of an already-committed operation: return the original
        -- committed result. Nothing is written again.
        RETURN v_receipt.result
            || jsonb_build_object('status', 'replayed', 'replayed', TRUE);
    END IF;

    -- ----------------------------------------------------------------
    -- 2.4 Lock and verify the OPD visit.
    -- ----------------------------------------------------------------
    SELECT * INTO v_opd
      FROM public.opd_registrations
     WHERE id = p_opd_registration_id
       AND deleted_at IS NULL
     FOR UPDATE;

    IF NOT FOUND THEN
        -- Retryable: the offline outbox uploads the visit BEFORE its payment.
        -- A missing visit means "not uploaded yet", never "reject forever".
        RAISE EXCEPTION 'hims_opd_payment_retry: opd visit % is not available yet', p_opd_registration_id
            USING ERRCODE = 'P0001';
    END IF;
    IF v_opd.hospital_id IS DISTINCT FROM v_hospital_id THEN
        RAISE EXCEPTION 'hims_opd_payment_forbidden: opd visit % belongs to another hospital', p_opd_registration_id
            USING ERRCODE = '42501';
    END IF;

    -- ----------------------------------------------------------------
    -- 2.5 Verify relationships (visit -> patient -> hospital).
    -- ----------------------------------------------------------------
    IF v_opd.patient_id IS DISTINCT FROM p_patient_id THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: visit % does not belong to patient %', p_opd_registration_id, p_patient_id
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM 1
       FROM public.patients
      WHERE id = p_patient_id
        AND hospital_id = v_hospital_id
        AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'hims_opd_payment_forbidden: patient % is not in the authenticated hospital', p_patient_id
            USING ERRCODE = '42501';
    END IF;

    -- ----------------------------------------------------------------
    -- 2.6 Validate amounts and the permitted payment transition.
    -- ----------------------------------------------------------------
    v_total := round(coalesce(v_opd.consultation_fee, 0), 2);

    IF p_consultation_fee IS NULL
       OR round(p_consultation_fee, 2) IS DISTINCT FROM v_total THEN
        RAISE EXCEPTION 'hims_opd_payment_conflict: consultation fee mismatch for visit % (client %, server %)',
            p_opd_registration_id, round(coalesce(p_consultation_fee, 0), 2), v_total
            USING ERRCODE = 'P0001';
    END IF;

    v_discount := round(coalesce(p_discount_amount, 0), 2);
    IF v_discount < 0 OR v_discount > v_total THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: discount % is outside 0..%', v_discount, v_total
            USING ERRCODE = 'P0001';
    END IF;

    v_net := round(v_total - v_discount, 2);
    v_paid := round(coalesce(p_payment_amount, 0), 2);
    IF v_paid < 0 OR v_paid > v_net THEN
        RAISE EXCEPTION 'hims_opd_payment_invalid: payment % is outside 0..% (net payable)', v_paid, v_net
            USING ERRCODE = 'P0001';
    END IF;
    v_balance := round(v_net - v_paid, 2);

    -- A visit that is already settled can never be settled again by a NEW
    -- operation id (an exact replay is handled by the receipt above). This is
    -- the "no duplicate collections" guard.
    IF v_opd.payment_status = 'paid' THEN
        RAISE EXCEPTION 'hims_opd_payment_conflict: visit % is already settled', p_opd_registration_id
            USING ERRCODE = 'P0001';
    END IF;

    -- One bill per OPD visit, and per visit only ONE collection through this
    -- operation. A bill is reusable by this operation only while it carries no
    -- collection at all (the narrow "a previous attempt materialised the bill
    -- but no money moved" resume case). Anything else is a conflict: silently
    -- re-deriving the amounts would change revenue without a matching payment
    -- record, which is exactly how a double/incorrect collection happens.
    SELECT * INTO v_existing_bill
      FROM public.billing
     WHERE opd_registration_id = p_opd_registration_id
       AND deleted_at IS NULL
     ORDER BY created_at
     LIMIT 1
     FOR UPDATE;

    IF FOUND THEN
        IF v_existing_bill.offline_id IS DISTINCT FROM p_bill_offline_id THEN
            RAISE EXCEPTION 'hims_opd_payment_conflict: a bill already exists for visit %', p_opd_registration_id
                USING ERRCODE = 'P0001';
        END IF;
        IF coalesce(v_existing_bill.paid_amount, 0) > 0
           OR v_existing_bill.payment_status = 'paid' THEN
            RAISE EXCEPTION 'hims_opd_payment_conflict: bill % already carries a collection', v_existing_bill.id
                USING ERRCODE = 'P0001';
        END IF;
        v_bill_exists := TRUE;
    END IF;

    -- Derived, not client-supplied: the caller cannot invent a status.
    v_status := CASE
        WHEN v_paid >= v_net THEN 'paid'
        WHEN v_paid > 0 THEN 'partially_paid'
        ELSE 'unpaid'
    END;
    v_bill_status := CASE WHEN v_status = 'paid' THEN 'paid' ELSE 'generated' END;
    v_mode := lower(btrim(coalesce(p_payment_mode, '')));
    v_discount_pct := CASE
        WHEN v_total > 0 THEN round(v_discount / v_total * 100, 2)
        ELSE 0
    END;
    v_bill_date := coalesce(v_opd.visit_date, CURRENT_DATE);
    v_bill_item_id := coalesce(p_bill_item_id, gen_random_uuid());
    v_payment_log_id := coalesce(p_payment_log_id, gen_random_uuid());

    -- ----------------------------------------------------------------
    -- 2.7 Apply the accounting rows (same transaction as the receipt).
    -- ----------------------------------------------------------------
    IF v_bill_exists THEN
        UPDATE public.billing SET
            subtotal            = v_total,
            total_amount        = v_total,
            discount_amount     = v_discount,
            discount_percentage = v_discount_pct,
            net_amount          = v_net,
            paid_amount         = v_paid,
            balance_amount      = v_balance,
            payment_status      = v_status,
            payment_mode        = v_mode,
            payment_date        = CASE WHEN v_paid > 0 THEN v_now ELSE NULL END,
            status              = v_bill_status,
            updated_by          = v_user_id,
            updated_at          = v_now
        WHERE id = v_existing_bill.id
        RETURNING * INTO v_bill;
    ELSE
        BEGIN
            INSERT INTO public.billing (
                id, offline_id, sync_status, hospital_id, patient_id,
                opd_registration_id, source_type, bill_number, bill_date,
                bill_type, visit_type, subtotal, total_amount, discount_amount,
                discount_percentage, tax_amount, net_amount, paid_amount,
                balance_amount, payment_status, payment_mode, payment_date,
                status, created_by, updated_by, created_at, updated_at
            ) VALUES (
                p_bill_id, p_bill_offline_id, 'synced', v_hospital_id, p_patient_id,
                p_opd_registration_id, 'opd', btrim(p_bill_number), v_bill_date,
                'opd', 'opd', v_total, v_total, v_discount,
                v_discount_pct, 0, v_net, v_paid,
                v_balance, v_status, v_mode,
                CASE WHEN v_paid > 0 THEN v_now ELSE NULL END,
                v_bill_status, v_user_id, v_user_id, v_now, v_now
            )
            RETURNING * INTO v_bill;
        EXCEPTION
            WHEN unique_violation THEN
                -- e.g. the bill number is already used by another bill.
                RAISE EXCEPTION 'hims_opd_payment_conflict: bill % could not be created (duplicate bill number %)',
                    p_bill_id, btrim(p_bill_number)
                    USING ERRCODE = 'P0001';
        END;

        -- Line item: only when this operation created the bill (mirrors the
        -- existing online behaviour, which does not re-add items to an
        -- existing bill).
        IF NOT EXISTS (
            SELECT 1 FROM public.billing_items
             WHERE id = v_bill_item_id
               AND bill_id <> v_bill.id
        ) THEN
            INSERT INTO public.billing_items (
                id, bill_id, hospital_id, item_type, item_name,
                quantity, unit_price, total_price
            ) VALUES (
                v_bill_item_id, v_bill.id, v_hospital_id, 'consultation',
                'Consultation Fee', 1, v_total, v_total
            )
            ON CONFLICT (id) DO NOTHING;
        END IF;

        INSERT INTO public.billing_audit (
            bill_id, action, old_value, new_value, description, performed_by
        ) VALUES (
            v_bill.id, 'created', NULL,
            to_jsonb(v_bill) - 'deleted_at',
            'OPD payment operation materialised into the unified billing system',
            v_user_id
        );
    END IF;

    -- Payment log: exactly one per operation, and never a second one for a
    -- bill that already carries a payment (idempotent on retry).
    IF v_paid > 0 THEN
        SELECT EXISTS (
            SELECT 1 FROM public.payment_logs
             WHERE bill_id = v_bill.id
               AND deleted_at IS NULL
        ) INTO v_payment_exists;

        IF NOT v_payment_exists THEN
            INSERT INTO public.payment_logs (
                id, bill_id, hospital_id, amount_paid, payment_amount,
                payment_mode, payment_date, paid_by, recorded_by, created_at
            ) VALUES (
                v_payment_log_id, v_bill.id, v_hospital_id, v_paid, v_paid,
                v_mode, v_now, NULL, v_user_id, v_now
            )
            ON CONFLICT (id) DO NOTHING;

            INSERT INTO public.billing_audit (
                bill_id, action, old_value, new_value, description, performed_by
            ) VALUES (
                v_bill.id, 'payment_added',
                jsonb_build_object('paid_amount', 0),
                jsonb_build_object('paid_amount', v_paid),
                format('OPD payment of %s received via %s', v_paid, upper(v_mode)),
                v_user_id
            );
        END IF;
    ELSE
        v_payment_log_id := NULL;
    END IF;

    -- The visit's own payment columns (existing online behaviour, preserved:
    -- payment_amount carries the net payable, paid_amount the collection).
    UPDATE public.opd_registrations SET
        payment_amount = v_net,
        payment_mode   = v_mode,
        payment_status = v_status,
        paid_amount    = v_paid,
        balance_amount = v_balance,
        updated_at     = v_now
    WHERE id = v_opd.id;

    -- ----------------------------------------------------------------
    -- 2.8 Finalise the receipt (still the same transaction).
    -- ----------------------------------------------------------------
    v_result := jsonb_build_object(
        'status', 'applied',
        'replayed', FALSE,
        'operation_id', p_operation_id,
        'operation_type', 'opd_payment',
        'hospital_id', v_hospital_id,
        'opd_registration_id', p_opd_registration_id,
        'patient_id', p_patient_id,
        'bill_id', v_bill.id,
        'bill_number', v_bill.bill_number,
        'bill_item_id', v_bill_item_id,
        'payment_log_id', v_payment_log_id,
        'consultation_fee', v_total,
        'discount_amount', v_discount,
        'net_amount', v_net,
        'paid_amount', v_paid,
        'balance_amount', v_balance,
        'payment_status', v_status,
        'bill_status', v_bill_status,
        'payment_mode', v_mode,
        'applied_at', to_jsonb(v_now)
    );

    UPDATE public.hims_operation_receipts
       SET result = v_result,
           operation_record_id = v_bill.id
     WHERE operation_id = p_operation_id;

    RETURN v_result;
END;
$func$;

-- ----------------------------------------------------------------------
-- 3. Execution permissions
--    * Only authenticated clients may call the operation.
--    * `anon` is revoked explicitly (a signed-out client must never be able
--      to move money).
-- ----------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.hims_apply_opd_payment(
    UUID, TEXT, UUID, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT,
    UUID, UUID, TEXT, UUID, UUID
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hims_apply_opd_payment(
    UUID, TEXT, UUID, UUID, NUMERIC, NUMERIC, NUMERIC, TEXT,
    UUID, UUID, TEXT, UUID, UUID
) TO authenticated;
