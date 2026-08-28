class ApiConstants {
  // Supabase Tables
  static const String usersTable = 'users';
  static const String userRolesTable = 'user_roles';
  static const String hospitalsTable = 'hospitals';
  static const String departmentsTable = 'departments';
  static const String patientsTable = 'patients';
  static const String patientInsurancesTable = 'patient_insurances';
  static const String abhaLinkingLogsTable = 'abha_linking_logs';
  static const String opdRegistrationsTable = 'opd_registrations';
  static const String ipdAdmissionsTable = 'ipd_admissions';
  static const String bedsTable = 'beds';
  static const String bedAllocationsTable = 'bed_allocations';
  static const String vitalsTable = 'vitals';
  static const String progressNotesTable = 'progress_notes';
  static const String prescriptionsTable = 'prescriptions';
  static const String prescriptionItemsTable = 'prescription_items';
  static const String investigationsTable = 'investigations';
  static const String investigationResultsTable = 'investigation_results';
  static const String medicationAdministrationTable =
      'medication_administration';
  static const String labTestsTable = 'lab_tests';
  static const String labOrdersTable = 'lab_orders';
  static const String labResultsTable = 'lab_results';
  static const String pharmacyMedicinesTable = 'pharmacy_medicines';
  static const String pharmacyStockTable = 'pharmacy_stock';
  static const String pharmacyPurchasesTable = 'pharmacy_purchases';
  static const String purchaseEntriesTable = 'purchase_entries';
  static const String stockChecksTable = 'stock_checks';
  static const String stockCheckDiscrepanciesTable =
      'stock_check_discrepancies';
  static const String dailyHisabTable = 'daily_hisab';
  static const String dailyHisabExpensesTable = 'daily_hisab_expenses';
  static const String billingTable = 'billing';
  static const String billingItemsTable = 'billing_items';
  static const String billEditsTable = 'bill_edits';
  static const String paymentLogsTable = 'payment_logs';
  static const String billingAuditTable = 'billing_audit';
  static const String paymentsTable = 'payments';
  static const String insuranceClaimsTable = 'insurance_claims';
  static const String careContextsTable = 'care_contexts';
  static const String consentArtefactsTable = 'consent_artefacts';
  static const String dataFlowLogsTable = 'data_flow_logs';
  static const String notificationsTable = 'notifications';
  static const String userDevicesTable = 'user_devices';
  static const String auditLogsTable = 'audit_logs';
  static const String doctorsTable = 'doctors';

  // IPD Discharge & Billing
  static const String ipdChargesTable = 'ipd_charges';
  static const String ipdPackagesTable = 'ipd_packages';
  static const String ipdWardPricingTable = 'ipd_ward_pricing';
  static const String ipdServiceMasterTable = 'ipd_service_master';
  static const String wardTransfersTable = 'ward_transfers';

  // IPD Patient Dashboard
  static const String ipdVitalsTable = 'ipd_vitals';
  static const String ipdProgressNotesTable = 'ipd_progress_notes';
  static const String ipdMedicationsTable = 'ipd_medications';
  static const String ipdReportsTable = 'ipd_reports';

  // Unified Lab / Diagnostics Module
  static const String diagnosticTestsTable = 'diagnostic_tests';
  static const String diagnosticOrdersTable = 'diagnostic_orders';
  static const String diagnosticOrderItemsTable = 'diagnostic_order_items';
  static const String diagnosticResultsTable = 'diagnostic_results';
  static const String labRevenueTable = 'lab_revenue';

  // Voucher / Expense Module
  static const String vouchersTable = 'vouchers';
  static const String voucherCategoriesTable = 'voucher_categories';
  static const String voucherSettingsTable = 'voucher_settings';

  // Reports Module
  static const String reportsTable = 'reports';

  // WhatsApp Marketing Module
  static const String whatsappSettingsTable = 'whatsapp_settings';
  static const String whatsappTemplatesTable = 'whatsapp_templates';
  static const String whatsappCampaignsTable = 'whatsapp_campaigns';
  static const String whatsappMessagesTable = 'whatsapp_messages';
  static const String whatsappOptOutsTable = 'whatsapp_opt_outs';

  // Meta WhatsApp Cloud API endpoints. The Graph API version is read from
  // WhatsappService so older/newer versions can be targeted without code
  // changes; these constants keep the canonical paths used by the service.
  static const String whatsappGraphBaseUrl = 'https://graph.facebook.com';
  static const String whatsappApiVersion = 'v21.0';
  static const String whatsappPhoneNumbersPath = '/{wabaId}/phone_numbers';
  static const String whatsappMessagesPath = '/{phoneNumberId}/messages';
  static const String whatsappTemplatesPath = '/{wabaId}/message_templates';

  // Clinical Counseling Documentation
  static const String counselingRecordsTable = 'counseling_records';
  static const String counselingMediaTable = 'counseling_media';
  static const String counselingConsentsTable = 'counseling_consents';

  // Compliance & Renewal Reminder Module
  static const String complianceRecordsTable = 'compliance_records';
  static const String complianceDocumentsTable = 'compliance_documents';
  static const String complianceRemindersTable = 'compliance_reminders';
  static const String complianceAuditLogsTable = 'compliance_audit_logs';

  // ABDM API Endpoints
  // Base URLs are read from AppConfig at runtime; these constants keep the
  // canonical paths used by AbdmService so screens never hard-code URLs.
  static const String abdmBaseUrl = 'https://sandbox.abdm.gov.in';

  // -- Gateway session / auth ------------------------------------------------
  static const String abdmSessions = '/v1/sessions';

  // -- M1: ABHA creation (Aadhaar OTP flow) ----------------------------------
  // ABDM exposes the same resource under v1 and v3; the service tries the
  // paths in order so a sandbox that has migrated API versions keeps working.
  static const List<String> abdmAadhaarGenerateOtpPaths = [
    '/v3/registration/aadhaar/generateOtp',
    '/v1/registration/aadhaar/generateOtp',
  ];
  static const List<String> abdmAadhaarVerifyOtpPaths = [
    '/v3/registration/aadhaar/verifyOTP',
    '/v1/registration/aadhaar/verifyOTP',
  ];
  static const List<String> abdmCreateHealthIdPaths = [
    '/v3/registration/aadhaar/createHealthIdWithPreVerified',
    '/v1/registration/aadhaar/createHealthIdWithPreVerified',
  ];

  // -- M1: ABHA search / verify / address ------------------------------------
  static const String abdmSearchByHealthId = '/v1/search/searchByHealthId';
  static const String abdmSearchByMobile = '/v1/search/searchByMobile';
  static const String abdmSearchByAbhaAddress = '/v1/search/searchByAbhaAddress';

  // ABHA card + QR (HIE-CM account APIs). X-Token is the ABHA session token
  // returned by the create/verify flow, or the gateway bearer token.
  static const String abdmGetAbhaCard = '/v1/account/getAbhaCard';
  static const String abdmGetPngCard = '/v1/account/getPngCard';
  static const String abdmGetQrCode = '/v1/account/qrCode/v1/getQrCode';

  // -- M2: HIP care-context linking ------------------------------------------
  static const String abdmLinkInit = '/v1/links/link/init';
  static const String abdmLinkConfirm = '/v1/links/link/confirm';
  static const String abdmLinkAddContexts = '/v1/links/link/addContexts';

  // -- M2/M3: Consent --------------------------------------------------------
  static const String abdmConsentRequestInit = '/v1/consent-requests/init';
  static const String abdmConsentRequestStatus = '/v1/consent-requests/status';

  // -- M3: HIU health-information data flow ----------------------------------
  static const String abdmHealthInformationRequest =
      '/v1/health-information/hip/request';
  static const String abdmHealthInformationStatus =
      '/v1/health-information/hip/status';
}
