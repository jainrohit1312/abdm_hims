import 'dart:convert';

/// Outcome of one outbox upload attempt.
enum OutboxUploadResult {
  /// Server acknowledged the operation (durable).
  acknowledged,

  /// Server already has this `offline_id` (idempotent replay) — treat as done.
  alreadyCommitted,

  /// A concurrent edit was detected — a conflict was recorded.
  conflict,

  /// Server rejected the operation for a non-retryable reason.
  rejected,

  /// A retryable failure occurred (network / timeout / auth refresh pending).
  retryableFailure,
}

/// Lifecycle of a single local write operation.
enum SyncOperationType {
  create,
  update,
  delete;

  String get wire => name;

  static SyncOperationType fromWire(String? value) {
    switch (value) {
      case 'update':
        return SyncOperationType.update;
      case 'delete':
        return SyncOperationType.delete;
      case 'create':
      default:
        return SyncOperationType.create;
    }
  }
}

/// State of an outbox entry as it moves through the sync engine.
enum SyncOperationStatus {
  /// Saved locally, not yet attempted.
  pending,

  /// Currently being uploaded (transient; only meaningful while a pass runs).
  inFlight,

  /// Server acknowledged the operation (durable).
  synced,

  /// Upload failed with a retryable (network) error.
  failed,

  /// Server rejected the operation with a non-retryable auth/validation error.
  rejected,

  /// A concurrent edit was detected; both sides preserved until resolved.
  conflict,
}

/// A single durable outbox entry describing one create/update/delete.
class OutboxEntry {
  const OutboxEntry({
    required this.operationId,
    required this.hospitalId,
    required this.deviceId,
    required this.entity,
    required this.recordId,
    required this.operationType,
    required this.payload,
    this.baseVersion,
    this.dependencyGroup,
    this.attemptCount = 0,
    this.nextRetryAt,
    this.status = SyncOperationStatus.pending,
    this.lastError,
    this.createdAt,
  });

  /// Stable, locally generated UUID that is preserved through sync so the
  /// server can deduplicate a retried write (`offline_id`).
  final String operationId;

  /// Owning tenant. Never synced across hospitals.
  final String hospitalId;

  /// Originating device. Used for diagnostics + ownership policy.
  final String deviceId;

  /// Supabase table name (e.g. `patients`, `opd_registrations`, `billing`).
  final String entity;

  /// Business record id (stable local UUID preserved into the row).
  final String recordId;

  final SyncOperationType operationType;

  /// Full row payload (JSON-serialisable). For `delete` this may be empty.
  final Map<String, dynamic> payload;

  /// Server `sync_version` (or null for a brand-new row) this edit was based
  /// on — used for optimistic concurrency / conflict detection.
  final int? baseVersion;

  /// Parent/transaction group id so child rows wait for their parent.
  final String? dependencyGroup;

  final int attemptCount;
  final DateTime? nextRetryAt;
  final SyncOperationStatus status;
  final String? lastError;
  final DateTime? createdAt;

  OutboxEntry copyWith({
    int? attemptCount,
    DateTime? nextRetryAt,
    SyncOperationStatus? status,
    String? lastError,
    Map<String, dynamic>? payload,
    int? baseVersion,
  }) {
    return OutboxEntry(
      operationId: operationId,
      hospitalId: hospitalId,
      deviceId: deviceId,
      entity: entity,
      recordId: recordId,
      operationType: operationType,
      payload: payload ?? this.payload,
      baseVersion: baseVersion ?? this.baseVersion,
      dependencyGroup: dependencyGroup,
      attemptCount: attemptCount ?? this.attemptCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      status: status ?? this.status,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'operation_id': operationId,
    'hospital_id': hospitalId,
    'device_id': deviceId,
    'entity': entity,
    'record_id': recordId,
    'operation_type': operationType.wire,
    'payload': payload,
    'base_version': baseVersion,
    'dependency_group': dependencyGroup,
    'attempt_count': attemptCount,
    'next_retry_at': nextRetryAt?.toIso8601String(),
    'status': status.name,
    'last_error': lastError,
    'created_at': createdAt?.toIso8601String(),
  };

  factory OutboxEntry.fromJson(Map<String, dynamic> json) {
    return OutboxEntry(
      operationId: json['operation_id'] as String,
      hospitalId: json['hospital_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      entity: json['entity'] as String,
      recordId: json['record_id'] as String,
      operationType: SyncOperationType.fromWire(
        json['operation_type'] as String?,
      ),
      payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      baseVersion: json['base_version'] as int?,
      dependencyGroup: json['dependency_group'] as String?,
      attemptCount: json['attempt_count'] as int? ?? 0,
      nextRetryAt: json['next_retry_at'] == null
          ? null
          : DateTime.tryParse(json['next_retry_at'] as String),
      status: SyncOperationStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => SyncOperationStatus.pending,
      ),
      lastError: json['last_error'] as String?,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'] as String),
    );
  }
}

/// Durable per-hospital/per-dataset pull cursor.
class SyncCursor {
  const SyncCursor({
    required this.dataset,
    required this.value,
    this.updatedAt,
  });

  /// Dataset key, e.g. `patients`, `opd_registrations`.
  final String dataset;

  /// Last server version value (a `sync_version` number or ISO `updated_at`).
  final String value;

  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'dataset': dataset,
    'value': value,
    'updated_at': updatedAt?.toIso8601String(),
  };

  factory SyncCursor.fromJson(Map<String, dynamic> json) => SyncCursor(
    dataset: json['dataset'] as String,
    value: json['value'] as String? ?? '',
    updatedAt: json['updated_at'] == null
        ? null
        : DateTime.tryParse(json['updated_at'] as String),
  );
}

/// A locally preserved conflict (both sides) pending resolution.
class SyncConflict {
  const SyncConflict({
    required this.entity,
    required this.recordId,
    required this.localPayload,
    required this.remotePayload,
    required this.baseVersion,
    required this.detectedAt,
  });

  final String entity;
  final String recordId;
  final Map<String, dynamic> localPayload;
  final Map<String, dynamic> remotePayload;
  final int baseVersion;
  final DateTime detectedAt;

  Map<String, dynamic> toJson() => {
    'entity': entity,
    'record_id': recordId,
    'local_payload': jsonEncode(localPayload),
    'remote_payload': jsonEncode(remotePayload),
    'base_version': baseVersion,
    'detected_at': detectedAt.toIso8601String(),
  };

  factory SyncConflict.fromJson(Map<String, dynamic> json) => SyncConflict(
    entity: json['entity'] as String,
    recordId: json['record_id'] as String,
    localPayload: (jsonDecode(json['local_payload'] as String) as Map)
        .cast<String, dynamic>(),
    remotePayload: (jsonDecode(json['remote_payload'] as String) as Map)
        .cast<String, dynamic>(),
    baseVersion: json['base_version'] as int? ?? 0,
    detectedAt:
        DateTime.tryParse(json['detected_at'] as String? ?? '') ??
        DateTime.now(),
  );
}
