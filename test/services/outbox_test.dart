import 'package:abdm_hims/services/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OutboxEntry serialization', () {
    test('round-trips all fields', () {
      final entry = OutboxEntry(
        operationId: 'op-1',
        hospitalId: 'hosp-1',
        deviceId: 'dev-1',
        entity: 'patients',
        recordId: 'rec-1',
        operationType: SyncOperationType.create,
        payload: {'uhid': 'OPD123', 'first_name': 'A'},
        baseVersion: 7,
        dependencyGroup: 'opd-rec-1',
        attemptCount: 3,
        nextRetryAt: DateTime.utc(2026, 9, 11, 10),
        status: SyncOperationStatus.failed,
        lastError: 'timeout',
        createdAt: DateTime.utc(2026, 9, 11, 9),
      );

      final restored = OutboxEntry.fromJson(entry.toJson());

      expect(restored.operationId, 'op-1');
      expect(restored.hospitalId, 'hosp-1');
      expect(restored.deviceId, 'dev-1');
      expect(restored.entity, 'patients');
      expect(restored.recordId, 'rec-1');
      expect(restored.operationType, SyncOperationType.create);
      expect(restored.payload['uhid'], 'OPD123');
      expect(restored.baseVersion, 7);
      expect(restored.dependencyGroup, 'opd-rec-1');
      expect(restored.attemptCount, 3);
      expect(restored.nextRetryAt, DateTime.utc(2026, 9, 11, 10));
      expect(restored.status, SyncOperationStatus.failed);
      expect(restored.lastError, 'timeout');
      expect(restored.createdAt, DateTime.utc(2026, 9, 11, 9));
    });

    test('round-trips nullable fields as null', () {
      final entry = OutboxEntry(
        operationId: 'op-2',
        hospitalId: '',
        deviceId: '',
        entity: 'billing',
        recordId: 'rec-2',
        operationType: SyncOperationType.delete,
        payload: const {},
      );

      final restored = OutboxEntry.fromJson(entry.toJson());

      expect(restored.baseVersion, isNull);
      expect(restored.dependencyGroup, isNull);
      expect(restored.nextRetryAt, isNull);
      expect(restored.lastError, isNull);
      expect(restored.status, SyncOperationStatus.pending);
    });
  });

  group('SyncCursor serialization', () {
    test('round-trips', () {
      final cursor = SyncCursor(
        dataset: 'patients',
        value: '2026-09-11T10:00:00.000Z',
        updatedAt: DateTime.utc(2026, 9, 11, 10),
      );
      final restored = SyncCursor.fromJson(cursor.toJson());
      expect(restored.dataset, 'patients');
      expect(restored.value, '2026-09-11T10:00:00.000Z');
      expect(restored.updatedAt, DateTime.utc(2026, 9, 11, 10));
    });
  });

  group('SyncConflict serialization', () {
    test('round-trips both sides', () {
      final conflict = SyncConflict(
        entity: 'patients',
        recordId: 'rec-1',
        localPayload: {'first_name': 'Local'},
        remotePayload: {'first_name': 'Remote'},
        baseVersion: 5,
        detectedAt: DateTime.utc(2026, 9, 11),
      );
      final restored = SyncConflict.fromJson(conflict.toJson());
      expect(restored.entity, 'patients');
      expect(restored.recordId, 'rec-1');
      expect(restored.localPayload['first_name'], 'Local');
      expect(restored.remotePayload['first_name'], 'Remote');
      expect(restored.baseVersion, 5);
    });
  });
}
