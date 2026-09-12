// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_db_io.dart';

// ignore_for_file: type=lint
class $PatientRecordsTable extends PatientRecords
    with TableInfo<$PatientRecordsTable, OfflinePatient> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PatientRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _offlineIdMeta =
      const VerificationMeta('offlineId');
  @override
  late final GeneratedColumn<String> offlineId = GeneratedColumn<String>(
      'offline_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isSyncedMeta =
      const VerificationMeta('isSynced');
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
      'is_synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [offlineId, isSynced, payload, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'patient_records';
  @override
  VerificationContext validateIntegrity(Insertable<OfflinePatient> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('offline_id')) {
      context.handle(_offlineIdMeta,
          offlineId.isAcceptableOrUnknown(data['offline_id']!, _offlineIdMeta));
    } else if (isInserting) {
      context.missing(_offlineIdMeta);
    }
    if (data.containsKey('is_synced')) {
      context.handle(_isSyncedMeta,
          isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {offlineId};
  @override
  OfflinePatient map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflinePatient(
      offlineId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}offline_id'])!,
      isSynced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_synced'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $PatientRecordsTable createAlias(String alias) {
    return $PatientRecordsTable(attachedDatabase, alias);
  }
}

class OfflinePatient extends DataClass implements Insertable<OfflinePatient> {
  final String offlineId;
  final bool isSynced;
  final String payload;
  final int updatedAt;
  const OfflinePatient(
      {required this.offlineId,
      required this.isSynced,
      required this.payload,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['offline_id'] = Variable<String>(offlineId);
    map['is_synced'] = Variable<bool>(isSynced);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  PatientRecordsCompanion toCompanion(bool nullToAbsent) {
    return PatientRecordsCompanion(
      offlineId: Value(offlineId),
      isSynced: Value(isSynced),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory OfflinePatient.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflinePatient(
      offlineId: serializer.fromJson<String>(json['offlineId']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'offlineId': serializer.toJson<String>(offlineId),
      'isSynced': serializer.toJson<bool>(isSynced),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  OfflinePatient copyWith(
          {String? offlineId,
          bool? isSynced,
          String? payload,
          int? updatedAt}) =>
      OfflinePatient(
        offlineId: offlineId ?? this.offlineId,
        isSynced: isSynced ?? this.isSynced,
        payload: payload ?? this.payload,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('OfflinePatient(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(offlineId, isSynced, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflinePatient &&
          other.offlineId == this.offlineId &&
          other.isSynced == this.isSynced &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class PatientRecordsCompanion extends UpdateCompanion<OfflinePatient> {
  final Value<String> offlineId;
  final Value<bool> isSynced;
  final Value<String> payload;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const PatientRecordsCompanion({
    this.offlineId = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PatientRecordsCompanion.insert({
    required String offlineId,
    this.isSynced = const Value.absent(),
    required String payload,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : offlineId = Value(offlineId),
        payload = Value(payload),
        updatedAt = Value(updatedAt);
  static Insertable<OfflinePatient> custom({
    Expression<String>? offlineId,
    Expression<bool>? isSynced,
    Expression<String>? payload,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (offlineId != null) 'offline_id': offlineId,
      if (isSynced != null) 'is_synced': isSynced,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PatientRecordsCompanion copyWith(
      {Value<String>? offlineId,
      Value<bool>? isSynced,
      Value<String>? payload,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return PatientRecordsCompanion(
      offlineId: offlineId ?? this.offlineId,
      isSynced: isSynced ?? this.isSynced,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (offlineId.present) {
      map['offline_id'] = Variable<String>(offlineId.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PatientRecordsCompanion(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OpdRegistrationRecordsTable extends OpdRegistrationRecords
    with TableInfo<$OpdRegistrationRecordsTable, OfflineOpdRegistration> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OpdRegistrationRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _offlineIdMeta =
      const VerificationMeta('offlineId');
  @override
  late final GeneratedColumn<String> offlineId = GeneratedColumn<String>(
      'offline_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isSyncedMeta =
      const VerificationMeta('isSynced');
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
      'is_synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [offlineId, isSynced, payload, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'opd_registration_records';
  @override
  VerificationContext validateIntegrity(
      Insertable<OfflineOpdRegistration> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('offline_id')) {
      context.handle(_offlineIdMeta,
          offlineId.isAcceptableOrUnknown(data['offline_id']!, _offlineIdMeta));
    } else if (isInserting) {
      context.missing(_offlineIdMeta);
    }
    if (data.containsKey('is_synced')) {
      context.handle(_isSyncedMeta,
          isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {offlineId};
  @override
  OfflineOpdRegistration map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineOpdRegistration(
      offlineId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}offline_id'])!,
      isSynced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_synced'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $OpdRegistrationRecordsTable createAlias(String alias) {
    return $OpdRegistrationRecordsTable(attachedDatabase, alias);
  }
}

class OfflineOpdRegistration extends DataClass
    implements Insertable<OfflineOpdRegistration> {
  final String offlineId;
  final bool isSynced;
  final String payload;
  final int updatedAt;
  const OfflineOpdRegistration(
      {required this.offlineId,
      required this.isSynced,
      required this.payload,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['offline_id'] = Variable<String>(offlineId);
    map['is_synced'] = Variable<bool>(isSynced);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  OpdRegistrationRecordsCompanion toCompanion(bool nullToAbsent) {
    return OpdRegistrationRecordsCompanion(
      offlineId: Value(offlineId),
      isSynced: Value(isSynced),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory OfflineOpdRegistration.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineOpdRegistration(
      offlineId: serializer.fromJson<String>(json['offlineId']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'offlineId': serializer.toJson<String>(offlineId),
      'isSynced': serializer.toJson<bool>(isSynced),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  OfflineOpdRegistration copyWith(
          {String? offlineId,
          bool? isSynced,
          String? payload,
          int? updatedAt}) =>
      OfflineOpdRegistration(
        offlineId: offlineId ?? this.offlineId,
        isSynced: isSynced ?? this.isSynced,
        payload: payload ?? this.payload,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('OfflineOpdRegistration(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(offlineId, isSynced, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineOpdRegistration &&
          other.offlineId == this.offlineId &&
          other.isSynced == this.isSynced &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class OpdRegistrationRecordsCompanion
    extends UpdateCompanion<OfflineOpdRegistration> {
  final Value<String> offlineId;
  final Value<bool> isSynced;
  final Value<String> payload;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const OpdRegistrationRecordsCompanion({
    this.offlineId = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OpdRegistrationRecordsCompanion.insert({
    required String offlineId,
    this.isSynced = const Value.absent(),
    required String payload,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : offlineId = Value(offlineId),
        payload = Value(payload),
        updatedAt = Value(updatedAt);
  static Insertable<OfflineOpdRegistration> custom({
    Expression<String>? offlineId,
    Expression<bool>? isSynced,
    Expression<String>? payload,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (offlineId != null) 'offline_id': offlineId,
      if (isSynced != null) 'is_synced': isSynced,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OpdRegistrationRecordsCompanion copyWith(
      {Value<String>? offlineId,
      Value<bool>? isSynced,
      Value<String>? payload,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return OpdRegistrationRecordsCompanion(
      offlineId: offlineId ?? this.offlineId,
      isSynced: isSynced ?? this.isSynced,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (offlineId.present) {
      map['offline_id'] = Variable<String>(offlineId.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OpdRegistrationRecordsCompanion(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IpdAdmissionRecordsTable extends IpdAdmissionRecords
    with TableInfo<$IpdAdmissionRecordsTable, OfflineIpdAdmission> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IpdAdmissionRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _offlineIdMeta =
      const VerificationMeta('offlineId');
  @override
  late final GeneratedColumn<String> offlineId = GeneratedColumn<String>(
      'offline_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isSyncedMeta =
      const VerificationMeta('isSynced');
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
      'is_synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [offlineId, isSynced, payload, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ipd_admission_records';
  @override
  VerificationContext validateIntegrity(
      Insertable<OfflineIpdAdmission> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('offline_id')) {
      context.handle(_offlineIdMeta,
          offlineId.isAcceptableOrUnknown(data['offline_id']!, _offlineIdMeta));
    } else if (isInserting) {
      context.missing(_offlineIdMeta);
    }
    if (data.containsKey('is_synced')) {
      context.handle(_isSyncedMeta,
          isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {offlineId};
  @override
  OfflineIpdAdmission map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineIpdAdmission(
      offlineId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}offline_id'])!,
      isSynced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_synced'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $IpdAdmissionRecordsTable createAlias(String alias) {
    return $IpdAdmissionRecordsTable(attachedDatabase, alias);
  }
}

class OfflineIpdAdmission extends DataClass
    implements Insertable<OfflineIpdAdmission> {
  final String offlineId;
  final bool isSynced;
  final String payload;
  final int updatedAt;
  const OfflineIpdAdmission(
      {required this.offlineId,
      required this.isSynced,
      required this.payload,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['offline_id'] = Variable<String>(offlineId);
    map['is_synced'] = Variable<bool>(isSynced);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  IpdAdmissionRecordsCompanion toCompanion(bool nullToAbsent) {
    return IpdAdmissionRecordsCompanion(
      offlineId: Value(offlineId),
      isSynced: Value(isSynced),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory OfflineIpdAdmission.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineIpdAdmission(
      offlineId: serializer.fromJson<String>(json['offlineId']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'offlineId': serializer.toJson<String>(offlineId),
      'isSynced': serializer.toJson<bool>(isSynced),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  OfflineIpdAdmission copyWith(
          {String? offlineId,
          bool? isSynced,
          String? payload,
          int? updatedAt}) =>
      OfflineIpdAdmission(
        offlineId: offlineId ?? this.offlineId,
        isSynced: isSynced ?? this.isSynced,
        payload: payload ?? this.payload,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('OfflineIpdAdmission(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(offlineId, isSynced, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineIpdAdmission &&
          other.offlineId == this.offlineId &&
          other.isSynced == this.isSynced &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class IpdAdmissionRecordsCompanion
    extends UpdateCompanion<OfflineIpdAdmission> {
  final Value<String> offlineId;
  final Value<bool> isSynced;
  final Value<String> payload;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const IpdAdmissionRecordsCompanion({
    this.offlineId = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IpdAdmissionRecordsCompanion.insert({
    required String offlineId,
    this.isSynced = const Value.absent(),
    required String payload,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : offlineId = Value(offlineId),
        payload = Value(payload),
        updatedAt = Value(updatedAt);
  static Insertable<OfflineIpdAdmission> custom({
    Expression<String>? offlineId,
    Expression<bool>? isSynced,
    Expression<String>? payload,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (offlineId != null) 'offline_id': offlineId,
      if (isSynced != null) 'is_synced': isSynced,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IpdAdmissionRecordsCompanion copyWith(
      {Value<String>? offlineId,
      Value<bool>? isSynced,
      Value<String>? payload,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return IpdAdmissionRecordsCompanion(
      offlineId: offlineId ?? this.offlineId,
      isSynced: isSynced ?? this.isSynced,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (offlineId.present) {
      map['offline_id'] = Variable<String>(offlineId.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IpdAdmissionRecordsCompanion(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BillingRecordsTable extends BillingRecords
    with TableInfo<$BillingRecordsTable, OfflineBilling> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BillingRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _offlineIdMeta =
      const VerificationMeta('offlineId');
  @override
  late final GeneratedColumn<String> offlineId = GeneratedColumn<String>(
      'offline_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _isSyncedMeta =
      const VerificationMeta('isSynced');
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
      'is_synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [offlineId, isSynced, payload, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'billing_records';
  @override
  VerificationContext validateIntegrity(Insertable<OfflineBilling> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('offline_id')) {
      context.handle(_offlineIdMeta,
          offlineId.isAcceptableOrUnknown(data['offline_id']!, _offlineIdMeta));
    } else if (isInserting) {
      context.missing(_offlineIdMeta);
    }
    if (data.containsKey('is_synced')) {
      context.handle(_isSyncedMeta,
          isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta));
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {offlineId};
  @override
  OfflineBilling map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineBilling(
      offlineId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}offline_id'])!,
      isSynced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_synced'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $BillingRecordsTable createAlias(String alias) {
    return $BillingRecordsTable(attachedDatabase, alias);
  }
}

class OfflineBilling extends DataClass implements Insertable<OfflineBilling> {
  final String offlineId;
  final bool isSynced;
  final String payload;
  final int updatedAt;
  const OfflineBilling(
      {required this.offlineId,
      required this.isSynced,
      required this.payload,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['offline_id'] = Variable<String>(offlineId);
    map['is_synced'] = Variable<bool>(isSynced);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  BillingRecordsCompanion toCompanion(bool nullToAbsent) {
    return BillingRecordsCompanion(
      offlineId: Value(offlineId),
      isSynced: Value(isSynced),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory OfflineBilling.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineBilling(
      offlineId: serializer.fromJson<String>(json['offlineId']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'offlineId': serializer.toJson<String>(offlineId),
      'isSynced': serializer.toJson<bool>(isSynced),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  OfflineBilling copyWith(
          {String? offlineId,
          bool? isSynced,
          String? payload,
          int? updatedAt}) =>
      OfflineBilling(
        offlineId: offlineId ?? this.offlineId,
        isSynced: isSynced ?? this.isSynced,
        payload: payload ?? this.payload,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('OfflineBilling(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(offlineId, isSynced, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineBilling &&
          other.offlineId == this.offlineId &&
          other.isSynced == this.isSynced &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class BillingRecordsCompanion extends UpdateCompanion<OfflineBilling> {
  final Value<String> offlineId;
  final Value<bool> isSynced;
  final Value<String> payload;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const BillingRecordsCompanion({
    this.offlineId = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BillingRecordsCompanion.insert({
    required String offlineId,
    this.isSynced = const Value.absent(),
    required String payload,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : offlineId = Value(offlineId),
        payload = Value(payload),
        updatedAt = Value(updatedAt);
  static Insertable<OfflineBilling> custom({
    Expression<String>? offlineId,
    Expression<bool>? isSynced,
    Expression<String>? payload,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (offlineId != null) 'offline_id': offlineId,
      if (isSynced != null) 'is_synced': isSynced,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BillingRecordsCompanion copyWith(
      {Value<String>? offlineId,
      Value<bool>? isSynced,
      Value<String>? payload,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return BillingRecordsCompanion(
      offlineId: offlineId ?? this.offlineId,
      isSynced: isSynced ?? this.isSynced,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (offlineId.present) {
      map['offline_id'] = Variable<String>(offlineId.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BillingRecordsCompanion(')
          ..write('offlineId: $offlineId, ')
          ..write('isSynced: $isSynced, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncOutboxEntriesTable extends SyncOutboxEntries
    with TableInfo<$SyncOutboxEntriesTable, OutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncOutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _operationIdMeta =
      const VerificationMeta('operationId');
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
      'operation_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _hospitalIdMeta =
      const VerificationMeta('hospitalId');
  @override
  late final GeneratedColumn<String> hospitalId = GeneratedColumn<String>(
      'hospital_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'device_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
      'entity', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _recordIdMeta =
      const VerificationMeta('recordId');
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
      'record_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _operationTypeMeta =
      const VerificationMeta('operationType');
  @override
  late final GeneratedColumn<String> operationType = GeneratedColumn<String>(
      'operation_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _baseVersionMeta =
      const VerificationMeta('baseVersion');
  @override
  late final GeneratedColumn<int> baseVersion = GeneratedColumn<int>(
      'base_version', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _dependencyGroupMeta =
      const VerificationMeta('dependencyGroup');
  @override
  late final GeneratedColumn<String> dependencyGroup = GeneratedColumn<String>(
      'dependency_group', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _nextRetryAtMeta =
      const VerificationMeta('nextRetryAt');
  @override
  late final GeneratedColumn<int> nextRetryAt = GeneratedColumn<int>(
      'next_retry_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('pending'));
  static const VerificationMeta _lastErrorMeta =
      const VerificationMeta('lastError');
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
      'last_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        operationId,
        hospitalId,
        deviceId,
        entity,
        recordId,
        operationType,
        payload,
        baseVersion,
        dependencyGroup,
        attemptCount,
        nextRetryAt,
        status,
        lastError,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_outbox_entries';
  @override
  VerificationContext validateIntegrity(Insertable<OutboxRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('operation_id')) {
      context.handle(
          _operationIdMeta,
          operationId.isAcceptableOrUnknown(
              data['operation_id']!, _operationIdMeta));
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('hospital_id')) {
      context.handle(
          _hospitalIdMeta,
          hospitalId.isAcceptableOrUnknown(
              data['hospital_id']!, _hospitalIdMeta));
    } else if (isInserting) {
      context.missing(_hospitalIdMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta));
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('entity')) {
      context.handle(_entityMeta,
          entity.isAcceptableOrUnknown(data['entity']!, _entityMeta));
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(_recordIdMeta,
          recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta));
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('operation_type')) {
      context.handle(
          _operationTypeMeta,
          operationType.isAcceptableOrUnknown(
              data['operation_type']!, _operationTypeMeta));
    } else if (isInserting) {
      context.missing(_operationTypeMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('base_version')) {
      context.handle(
          _baseVersionMeta,
          baseVersion.isAcceptableOrUnknown(
              data['base_version']!, _baseVersionMeta));
    }
    if (data.containsKey('dependency_group')) {
      context.handle(
          _dependencyGroupMeta,
          dependencyGroup.isAcceptableOrUnknown(
              data['dependency_group']!, _dependencyGroupMeta));
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
          _attemptCountMeta,
          attemptCount.isAcceptableOrUnknown(
              data['attempt_count']!, _attemptCountMeta));
    }
    if (data.containsKey('next_retry_at')) {
      context.handle(
          _nextRetryAtMeta,
          nextRetryAt.isAcceptableOrUnknown(
              data['next_retry_at']!, _nextRetryAtMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('last_error')) {
      context.handle(_lastErrorMeta,
          lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {operationId};
  @override
  OutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxRow(
      operationId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}operation_id'])!,
      hospitalId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}hospital_id'])!,
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}device_id'])!,
      entity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity'])!,
      recordId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}record_id'])!,
      operationType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}operation_type'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      baseVersion: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}base_version']),
      dependencyGroup: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}dependency_group']),
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      nextRetryAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}next_retry_at']),
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      lastError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_error']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $SyncOutboxEntriesTable createAlias(String alias) {
    return $SyncOutboxEntriesTable(attachedDatabase, alias);
  }
}

class OutboxRow extends DataClass implements Insertable<OutboxRow> {
  final String operationId;
  final String hospitalId;
  final String deviceId;
  final String entity;
  final String recordId;
  final String operationType;
  final String payload;
  final int? baseVersion;
  final String? dependencyGroup;
  final int attemptCount;
  final int? nextRetryAt;
  final String status;
  final String? lastError;
  final int createdAt;
  const OutboxRow(
      {required this.operationId,
      required this.hospitalId,
      required this.deviceId,
      required this.entity,
      required this.recordId,
      required this.operationType,
      required this.payload,
      this.baseVersion,
      this.dependencyGroup,
      required this.attemptCount,
      this.nextRetryAt,
      required this.status,
      this.lastError,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['operation_id'] = Variable<String>(operationId);
    map['hospital_id'] = Variable<String>(hospitalId);
    map['device_id'] = Variable<String>(deviceId);
    map['entity'] = Variable<String>(entity);
    map['record_id'] = Variable<String>(recordId);
    map['operation_type'] = Variable<String>(operationType);
    map['payload'] = Variable<String>(payload);
    if (!nullToAbsent || baseVersion != null) {
      map['base_version'] = Variable<int>(baseVersion);
    }
    if (!nullToAbsent || dependencyGroup != null) {
      map['dependency_group'] = Variable<String>(dependencyGroup);
    }
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextRetryAt != null) {
      map['next_retry_at'] = Variable<int>(nextRetryAt);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  SyncOutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return SyncOutboxEntriesCompanion(
      operationId: Value(operationId),
      hospitalId: Value(hospitalId),
      deviceId: Value(deviceId),
      entity: Value(entity),
      recordId: Value(recordId),
      operationType: Value(operationType),
      payload: Value(payload),
      baseVersion: baseVersion == null && nullToAbsent
          ? const Value.absent()
          : Value(baseVersion),
      dependencyGroup: dependencyGroup == null && nullToAbsent
          ? const Value.absent()
          : Value(dependencyGroup),
      attemptCount: Value(attemptCount),
      nextRetryAt: nextRetryAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextRetryAt),
      status: Value(status),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      createdAt: Value(createdAt),
    );
  }

  factory OutboxRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxRow(
      operationId: serializer.fromJson<String>(json['operationId']),
      hospitalId: serializer.fromJson<String>(json['hospitalId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      entity: serializer.fromJson<String>(json['entity']),
      recordId: serializer.fromJson<String>(json['recordId']),
      operationType: serializer.fromJson<String>(json['operationType']),
      payload: serializer.fromJson<String>(json['payload']),
      baseVersion: serializer.fromJson<int?>(json['baseVersion']),
      dependencyGroup: serializer.fromJson<String?>(json['dependencyGroup']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextRetryAt: serializer.fromJson<int?>(json['nextRetryAt']),
      status: serializer.fromJson<String>(json['status']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'operationId': serializer.toJson<String>(operationId),
      'hospitalId': serializer.toJson<String>(hospitalId),
      'deviceId': serializer.toJson<String>(deviceId),
      'entity': serializer.toJson<String>(entity),
      'recordId': serializer.toJson<String>(recordId),
      'operationType': serializer.toJson<String>(operationType),
      'payload': serializer.toJson<String>(payload),
      'baseVersion': serializer.toJson<int?>(baseVersion),
      'dependencyGroup': serializer.toJson<String?>(dependencyGroup),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextRetryAt': serializer.toJson<int?>(nextRetryAt),
      'status': serializer.toJson<String>(status),
      'lastError': serializer.toJson<String?>(lastError),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  OutboxRow copyWith(
          {String? operationId,
          String? hospitalId,
          String? deviceId,
          String? entity,
          String? recordId,
          String? operationType,
          String? payload,
          Value<int?> baseVersion = const Value.absent(),
          Value<String?> dependencyGroup = const Value.absent(),
          int? attemptCount,
          Value<int?> nextRetryAt = const Value.absent(),
          String? status,
          Value<String?> lastError = const Value.absent(),
          int? createdAt}) =>
      OutboxRow(
        operationId: operationId ?? this.operationId,
        hospitalId: hospitalId ?? this.hospitalId,
        deviceId: deviceId ?? this.deviceId,
        entity: entity ?? this.entity,
        recordId: recordId ?? this.recordId,
        operationType: operationType ?? this.operationType,
        payload: payload ?? this.payload,
        baseVersion: baseVersion.present ? baseVersion.value : this.baseVersion,
        dependencyGroup: dependencyGroup.present
            ? dependencyGroup.value
            : this.dependencyGroup,
        attemptCount: attemptCount ?? this.attemptCount,
        nextRetryAt: nextRetryAt.present ? nextRetryAt.value : this.nextRetryAt,
        status: status ?? this.status,
        lastError: lastError.present ? lastError.value : this.lastError,
        createdAt: createdAt ?? this.createdAt,
      );
  @override
  String toString() {
    return (StringBuffer('OutboxRow(')
          ..write('operationId: $operationId, ')
          ..write('hospitalId: $hospitalId, ')
          ..write('deviceId: $deviceId, ')
          ..write('entity: $entity, ')
          ..write('recordId: $recordId, ')
          ..write('operationType: $operationType, ')
          ..write('payload: $payload, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('dependencyGroup: $dependencyGroup, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('status: $status, ')
          ..write('lastError: $lastError, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      operationId,
      hospitalId,
      deviceId,
      entity,
      recordId,
      operationType,
      payload,
      baseVersion,
      dependencyGroup,
      attemptCount,
      nextRetryAt,
      status,
      lastError,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxRow &&
          other.operationId == this.operationId &&
          other.hospitalId == this.hospitalId &&
          other.deviceId == this.deviceId &&
          other.entity == this.entity &&
          other.recordId == this.recordId &&
          other.operationType == this.operationType &&
          other.payload == this.payload &&
          other.baseVersion == this.baseVersion &&
          other.dependencyGroup == this.dependencyGroup &&
          other.attemptCount == this.attemptCount &&
          other.nextRetryAt == this.nextRetryAt &&
          other.status == this.status &&
          other.lastError == this.lastError &&
          other.createdAt == this.createdAt);
}

class SyncOutboxEntriesCompanion extends UpdateCompanion<OutboxRow> {
  final Value<String> operationId;
  final Value<String> hospitalId;
  final Value<String> deviceId;
  final Value<String> entity;
  final Value<String> recordId;
  final Value<String> operationType;
  final Value<String> payload;
  final Value<int?> baseVersion;
  final Value<String?> dependencyGroup;
  final Value<int> attemptCount;
  final Value<int?> nextRetryAt;
  final Value<String> status;
  final Value<String?> lastError;
  final Value<int> createdAt;
  final Value<int> rowid;
  const SyncOutboxEntriesCompanion({
    this.operationId = const Value.absent(),
    this.hospitalId = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.entity = const Value.absent(),
    this.recordId = const Value.absent(),
    this.operationType = const Value.absent(),
    this.payload = const Value.absent(),
    this.baseVersion = const Value.absent(),
    this.dependencyGroup = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.status = const Value.absent(),
    this.lastError = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncOutboxEntriesCompanion.insert({
    required String operationId,
    required String hospitalId,
    required String deviceId,
    required String entity,
    required String recordId,
    required String operationType,
    required String payload,
    this.baseVersion = const Value.absent(),
    this.dependencyGroup = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.status = const Value.absent(),
    this.lastError = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  })  : operationId = Value(operationId),
        hospitalId = Value(hospitalId),
        deviceId = Value(deviceId),
        entity = Value(entity),
        recordId = Value(recordId),
        operationType = Value(operationType),
        payload = Value(payload),
        createdAt = Value(createdAt);
  static Insertable<OutboxRow> custom({
    Expression<String>? operationId,
    Expression<String>? hospitalId,
    Expression<String>? deviceId,
    Expression<String>? entity,
    Expression<String>? recordId,
    Expression<String>? operationType,
    Expression<String>? payload,
    Expression<int>? baseVersion,
    Expression<String>? dependencyGroup,
    Expression<int>? attemptCount,
    Expression<int>? nextRetryAt,
    Expression<String>? status,
    Expression<String>? lastError,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (operationId != null) 'operation_id': operationId,
      if (hospitalId != null) 'hospital_id': hospitalId,
      if (deviceId != null) 'device_id': deviceId,
      if (entity != null) 'entity': entity,
      if (recordId != null) 'record_id': recordId,
      if (operationType != null) 'operation_type': operationType,
      if (payload != null) 'payload': payload,
      if (baseVersion != null) 'base_version': baseVersion,
      if (dependencyGroup != null) 'dependency_group': dependencyGroup,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextRetryAt != null) 'next_retry_at': nextRetryAt,
      if (status != null) 'status': status,
      if (lastError != null) 'last_error': lastError,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncOutboxEntriesCompanion copyWith(
      {Value<String>? operationId,
      Value<String>? hospitalId,
      Value<String>? deviceId,
      Value<String>? entity,
      Value<String>? recordId,
      Value<String>? operationType,
      Value<String>? payload,
      Value<int?>? baseVersion,
      Value<String?>? dependencyGroup,
      Value<int>? attemptCount,
      Value<int?>? nextRetryAt,
      Value<String>? status,
      Value<String?>? lastError,
      Value<int>? createdAt,
      Value<int>? rowid}) {
    return SyncOutboxEntriesCompanion(
      operationId: operationId ?? this.operationId,
      hospitalId: hospitalId ?? this.hospitalId,
      deviceId: deviceId ?? this.deviceId,
      entity: entity ?? this.entity,
      recordId: recordId ?? this.recordId,
      operationType: operationType ?? this.operationType,
      payload: payload ?? this.payload,
      baseVersion: baseVersion ?? this.baseVersion,
      dependencyGroup: dependencyGroup ?? this.dependencyGroup,
      attemptCount: attemptCount ?? this.attemptCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      status: status ?? this.status,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (hospitalId.present) {
      map['hospital_id'] = Variable<String>(hospitalId.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (operationType.present) {
      map['operation_type'] = Variable<String>(operationType.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (baseVersion.present) {
      map['base_version'] = Variable<int>(baseVersion.value);
    }
    if (dependencyGroup.present) {
      map['dependency_group'] = Variable<String>(dependencyGroup.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextRetryAt.present) {
      map['next_retry_at'] = Variable<int>(nextRetryAt.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncOutboxEntriesCompanion(')
          ..write('operationId: $operationId, ')
          ..write('hospitalId: $hospitalId, ')
          ..write('deviceId: $deviceId, ')
          ..write('entity: $entity, ')
          ..write('recordId: $recordId, ')
          ..write('operationType: $operationType, ')
          ..write('payload: $payload, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('dependencyGroup: $dependencyGroup, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('status: $status, ')
          ..write('lastError: $lastError, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncCursorRecordsTable extends SyncCursorRecords
    with TableInfo<$SyncCursorRecordsTable, SyncCursorRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCursorRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _datasetMeta =
      const VerificationMeta('dataset');
  @override
  late final GeneratedColumn<String> dataset = GeneratedColumn<String>(
      'dataset', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [dataset, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_cursor_records';
  @override
  VerificationContext validateIntegrity(Insertable<SyncCursorRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('dataset')) {
      context.handle(_datasetMeta,
          dataset.isAcceptableOrUnknown(data['dataset']!, _datasetMeta));
    } else if (isInserting) {
      context.missing(_datasetMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {dataset};
  @override
  SyncCursorRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCursorRow(
      dataset: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}dataset'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SyncCursorRecordsTable createAlias(String alias) {
    return $SyncCursorRecordsTable(attachedDatabase, alias);
  }
}

class SyncCursorRow extends DataClass implements Insertable<SyncCursorRow> {
  final String dataset;
  final String value;
  final int updatedAt;
  const SyncCursorRow(
      {required this.dataset, required this.value, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['dataset'] = Variable<String>(dataset);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SyncCursorRecordsCompanion toCompanion(bool nullToAbsent) {
    return SyncCursorRecordsCompanion(
      dataset: Value(dataset),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory SyncCursorRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCursorRow(
      dataset: serializer.fromJson<String>(json['dataset']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'dataset': serializer.toJson<String>(dataset),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SyncCursorRow copyWith({String? dataset, String? value, int? updatedAt}) =>
      SyncCursorRow(
        dataset: dataset ?? this.dataset,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('SyncCursorRow(')
          ..write('dataset: $dataset, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(dataset, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCursorRow &&
          other.dataset == this.dataset &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class SyncCursorRecordsCompanion extends UpdateCompanion<SyncCursorRow> {
  final Value<String> dataset;
  final Value<String> value;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const SyncCursorRecordsCompanion({
    this.dataset = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCursorRecordsCompanion.insert({
    required String dataset,
    required String value,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : dataset = Value(dataset),
        value = Value(value),
        updatedAt = Value(updatedAt);
  static Insertable<SyncCursorRow> custom({
    Expression<String>? dataset,
    Expression<String>? value,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (dataset != null) 'dataset': dataset,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCursorRecordsCompanion copyWith(
      {Value<String>? dataset,
      Value<String>? value,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return SyncCursorRecordsCompanion(
      dataset: dataset ?? this.dataset,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (dataset.present) {
      map['dataset'] = Variable<String>(dataset.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorRecordsCompanion(')
          ..write('dataset: $dataset, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncConflictRecordsTable extends SyncConflictRecords
    with TableInfo<$SyncConflictRecordsTable, SyncConflictRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncConflictRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
      'entity', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _recordIdMeta =
      const VerificationMeta('recordId');
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
      'record_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localPayloadMeta =
      const VerificationMeta('localPayload');
  @override
  late final GeneratedColumn<String> localPayload = GeneratedColumn<String>(
      'local_payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remotePayloadMeta =
      const VerificationMeta('remotePayload');
  @override
  late final GeneratedColumn<String> remotePayload = GeneratedColumn<String>(
      'remote_payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _baseVersionMeta =
      const VerificationMeta('baseVersion');
  @override
  late final GeneratedColumn<int> baseVersion = GeneratedColumn<int>(
      'base_version', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _detectedAtMeta =
      const VerificationMeta('detectedAt');
  @override
  late final GeneratedColumn<int> detectedAt = GeneratedColumn<int>(
      'detected_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [entity, recordId, localPayload, remotePayload, baseVersion, detectedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_conflict_records';
  @override
  VerificationContext validateIntegrity(Insertable<SyncConflictRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity')) {
      context.handle(_entityMeta,
          entity.isAcceptableOrUnknown(data['entity']!, _entityMeta));
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(_recordIdMeta,
          recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta));
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('local_payload')) {
      context.handle(
          _localPayloadMeta,
          localPayload.isAcceptableOrUnknown(
              data['local_payload']!, _localPayloadMeta));
    } else if (isInserting) {
      context.missing(_localPayloadMeta);
    }
    if (data.containsKey('remote_payload')) {
      context.handle(
          _remotePayloadMeta,
          remotePayload.isAcceptableOrUnknown(
              data['remote_payload']!, _remotePayloadMeta));
    } else if (isInserting) {
      context.missing(_remotePayloadMeta);
    }
    if (data.containsKey('base_version')) {
      context.handle(
          _baseVersionMeta,
          baseVersion.isAcceptableOrUnknown(
              data['base_version']!, _baseVersionMeta));
    } else if (isInserting) {
      context.missing(_baseVersionMeta);
    }
    if (data.containsKey('detected_at')) {
      context.handle(
          _detectedAtMeta,
          detectedAt.isAcceptableOrUnknown(
              data['detected_at']!, _detectedAtMeta));
    } else if (isInserting) {
      context.missing(_detectedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entity, recordId};
  @override
  SyncConflictRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncConflictRow(
      entity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity'])!,
      recordId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}record_id'])!,
      localPayload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_payload'])!,
      remotePayload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_payload'])!,
      baseVersion: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}base_version'])!,
      detectedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}detected_at'])!,
    );
  }

  @override
  $SyncConflictRecordsTable createAlias(String alias) {
    return $SyncConflictRecordsTable(attachedDatabase, alias);
  }
}

class SyncConflictRow extends DataClass implements Insertable<SyncConflictRow> {
  final String entity;
  final String recordId;
  final String localPayload;
  final String remotePayload;
  final int baseVersion;
  final int detectedAt;
  const SyncConflictRow(
      {required this.entity,
      required this.recordId,
      required this.localPayload,
      required this.remotePayload,
      required this.baseVersion,
      required this.detectedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity'] = Variable<String>(entity);
    map['record_id'] = Variable<String>(recordId);
    map['local_payload'] = Variable<String>(localPayload);
    map['remote_payload'] = Variable<String>(remotePayload);
    map['base_version'] = Variable<int>(baseVersion);
    map['detected_at'] = Variable<int>(detectedAt);
    return map;
  }

  SyncConflictRecordsCompanion toCompanion(bool nullToAbsent) {
    return SyncConflictRecordsCompanion(
      entity: Value(entity),
      recordId: Value(recordId),
      localPayload: Value(localPayload),
      remotePayload: Value(remotePayload),
      baseVersion: Value(baseVersion),
      detectedAt: Value(detectedAt),
    );
  }

  factory SyncConflictRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncConflictRow(
      entity: serializer.fromJson<String>(json['entity']),
      recordId: serializer.fromJson<String>(json['recordId']),
      localPayload: serializer.fromJson<String>(json['localPayload']),
      remotePayload: serializer.fromJson<String>(json['remotePayload']),
      baseVersion: serializer.fromJson<int>(json['baseVersion']),
      detectedAt: serializer.fromJson<int>(json['detectedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entity': serializer.toJson<String>(entity),
      'recordId': serializer.toJson<String>(recordId),
      'localPayload': serializer.toJson<String>(localPayload),
      'remotePayload': serializer.toJson<String>(remotePayload),
      'baseVersion': serializer.toJson<int>(baseVersion),
      'detectedAt': serializer.toJson<int>(detectedAt),
    };
  }

  SyncConflictRow copyWith(
          {String? entity,
          String? recordId,
          String? localPayload,
          String? remotePayload,
          int? baseVersion,
          int? detectedAt}) =>
      SyncConflictRow(
        entity: entity ?? this.entity,
        recordId: recordId ?? this.recordId,
        localPayload: localPayload ?? this.localPayload,
        remotePayload: remotePayload ?? this.remotePayload,
        baseVersion: baseVersion ?? this.baseVersion,
        detectedAt: detectedAt ?? this.detectedAt,
      );
  @override
  String toString() {
    return (StringBuffer('SyncConflictRow(')
          ..write('entity: $entity, ')
          ..write('recordId: $recordId, ')
          ..write('localPayload: $localPayload, ')
          ..write('remotePayload: $remotePayload, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('detectedAt: $detectedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      entity, recordId, localPayload, remotePayload, baseVersion, detectedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncConflictRow &&
          other.entity == this.entity &&
          other.recordId == this.recordId &&
          other.localPayload == this.localPayload &&
          other.remotePayload == this.remotePayload &&
          other.baseVersion == this.baseVersion &&
          other.detectedAt == this.detectedAt);
}

class SyncConflictRecordsCompanion extends UpdateCompanion<SyncConflictRow> {
  final Value<String> entity;
  final Value<String> recordId;
  final Value<String> localPayload;
  final Value<String> remotePayload;
  final Value<int> baseVersion;
  final Value<int> detectedAt;
  final Value<int> rowid;
  const SyncConflictRecordsCompanion({
    this.entity = const Value.absent(),
    this.recordId = const Value.absent(),
    this.localPayload = const Value.absent(),
    this.remotePayload = const Value.absent(),
    this.baseVersion = const Value.absent(),
    this.detectedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncConflictRecordsCompanion.insert({
    required String entity,
    required String recordId,
    required String localPayload,
    required String remotePayload,
    required int baseVersion,
    required int detectedAt,
    this.rowid = const Value.absent(),
  })  : entity = Value(entity),
        recordId = Value(recordId),
        localPayload = Value(localPayload),
        remotePayload = Value(remotePayload),
        baseVersion = Value(baseVersion),
        detectedAt = Value(detectedAt);
  static Insertable<SyncConflictRow> custom({
    Expression<String>? entity,
    Expression<String>? recordId,
    Expression<String>? localPayload,
    Expression<String>? remotePayload,
    Expression<int>? baseVersion,
    Expression<int>? detectedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entity != null) 'entity': entity,
      if (recordId != null) 'record_id': recordId,
      if (localPayload != null) 'local_payload': localPayload,
      if (remotePayload != null) 'remote_payload': remotePayload,
      if (baseVersion != null) 'base_version': baseVersion,
      if (detectedAt != null) 'detected_at': detectedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncConflictRecordsCompanion copyWith(
      {Value<String>? entity,
      Value<String>? recordId,
      Value<String>? localPayload,
      Value<String>? remotePayload,
      Value<int>? baseVersion,
      Value<int>? detectedAt,
      Value<int>? rowid}) {
    return SyncConflictRecordsCompanion(
      entity: entity ?? this.entity,
      recordId: recordId ?? this.recordId,
      localPayload: localPayload ?? this.localPayload,
      remotePayload: remotePayload ?? this.remotePayload,
      baseVersion: baseVersion ?? this.baseVersion,
      detectedAt: detectedAt ?? this.detectedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (localPayload.present) {
      map['local_payload'] = Variable<String>(localPayload.value);
    }
    if (remotePayload.present) {
      map['remote_payload'] = Variable<String>(remotePayload.value);
    }
    if (baseVersion.present) {
      map['base_version'] = Variable<int>(baseVersion.value);
    }
    if (detectedAt.present) {
      map['detected_at'] = Variable<int>(detectedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncConflictRecordsCompanion(')
          ..write('entity: $entity, ')
          ..write('recordId: $recordId, ')
          ..write('localPayload: $localPayload, ')
          ..write('remotePayload: $remotePayload, ')
          ..write('baseVersion: $baseVersion, ')
          ..write('detectedAt: $detectedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppMetadataRecordsTable extends AppMetadataRecords
    with TableInfo<$AppMetadataRecordsTable, AppMetadataRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppMetadataRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_metadata_records';
  @override
  VerificationContext validateIntegrity(Insertable<AppMetadataRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppMetadataRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppMetadataRow(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $AppMetadataRecordsTable createAlias(String alias) {
    return $AppMetadataRecordsTable(attachedDatabase, alias);
  }
}

class AppMetadataRow extends DataClass implements Insertable<AppMetadataRow> {
  final String key;
  final String value;
  final int updatedAt;
  const AppMetadataRow(
      {required this.key, required this.value, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  AppMetadataRecordsCompanion toCompanion(bool nullToAbsent) {
    return AppMetadataRecordsCompanion(
      key: Value(key),
      value: Value(value),
      updatedAt: Value(updatedAt),
    );
  }

  factory AppMetadataRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppMetadataRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  AppMetadataRow copyWith({String? key, String? value, int? updatedAt}) =>
      AppMetadataRow(
        key: key ?? this.key,
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('AppMetadataRow(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppMetadataRow &&
          other.key == this.key &&
          other.value == this.value &&
          other.updatedAt == this.updatedAt);
}

class AppMetadataRecordsCompanion extends UpdateCompanion<AppMetadataRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const AppMetadataRecordsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppMetadataRecordsCompanion.insert({
    required String key,
    required String value,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value),
        updatedAt = Value(updatedAt);
  static Insertable<AppMetadataRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppMetadataRecordsCompanion copyWith(
      {Value<String>? key,
      Value<String>? value,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return AppMetadataRecordsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppMetadataRecordsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MirrorRecordsTable extends MirrorRecords
    with TableInfo<$MirrorRecordsTable, MirrorRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MirrorRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tableMeta = const VerificationMeta('table');
  @override
  late final GeneratedColumn<String> table = GeneratedColumn<String>(
      'table', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _offlineIdMeta =
      const VerificationMeta('offlineId');
  @override
  late final GeneratedColumn<String> offlineId = GeneratedColumn<String>(
      'offline_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadMeta =
      const VerificationMeta('payload');
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
      'payload', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [table, offlineId, payload, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mirror_records';
  @override
  VerificationContext validateIntegrity(Insertable<MirrorRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('table')) {
      context.handle(
          _tableMeta, table.isAcceptableOrUnknown(data['table']!, _tableMeta));
    } else if (isInserting) {
      context.missing(_tableMeta);
    }
    if (data.containsKey('offline_id')) {
      context.handle(_offlineIdMeta,
          offlineId.isAcceptableOrUnknown(data['offline_id']!, _offlineIdMeta));
    } else if (isInserting) {
      context.missing(_offlineIdMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(_payloadMeta,
          payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta));
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {table, offlineId};
  @override
  MirrorRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MirrorRow(
      table: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}table'])!,
      offlineId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}offline_id'])!,
      payload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $MirrorRecordsTable createAlias(String alias) {
    return $MirrorRecordsTable(attachedDatabase, alias);
  }
}

class MirrorRow extends DataClass implements Insertable<MirrorRow> {
  final String table;
  final String offlineId;
  final String payload;
  final int updatedAt;
  const MirrorRow(
      {required this.table,
      required this.offlineId,
      required this.payload,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['table'] = Variable<String>(table);
    map['offline_id'] = Variable<String>(offlineId);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  MirrorRecordsCompanion toCompanion(bool nullToAbsent) {
    return MirrorRecordsCompanion(
      table: Value(table),
      offlineId: Value(offlineId),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory MirrorRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MirrorRow(
      table: serializer.fromJson<String>(json['table']),
      offlineId: serializer.fromJson<String>(json['offlineId']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'table': serializer.toJson<String>(table),
      'offlineId': serializer.toJson<String>(offlineId),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  MirrorRow copyWith(
          {String? table,
          String? offlineId,
          String? payload,
          int? updatedAt}) =>
      MirrorRow(
        table: table ?? this.table,
        offlineId: offlineId ?? this.offlineId,
        payload: payload ?? this.payload,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  @override
  String toString() {
    return (StringBuffer('MirrorRow(')
          ..write('table: $table, ')
          ..write('offlineId: $offlineId, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(table, offlineId, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MirrorRow &&
          other.table == this.table &&
          other.offlineId == this.offlineId &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class MirrorRecordsCompanion extends UpdateCompanion<MirrorRow> {
  final Value<String> table;
  final Value<String> offlineId;
  final Value<String> payload;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const MirrorRecordsCompanion({
    this.table = const Value.absent(),
    this.offlineId = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MirrorRecordsCompanion.insert({
    required String table,
    required String offlineId,
    required String payload,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : table = Value(table),
        offlineId = Value(offlineId),
        payload = Value(payload),
        updatedAt = Value(updatedAt);
  static Insertable<MirrorRow> custom({
    Expression<String>? table,
    Expression<String>? offlineId,
    Expression<String>? payload,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (table != null) 'table': table,
      if (offlineId != null) 'offline_id': offlineId,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MirrorRecordsCompanion copyWith(
      {Value<String>? table,
      Value<String>? offlineId,
      Value<String>? payload,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return MirrorRecordsCompanion(
      table: table ?? this.table,
      offlineId: offlineId ?? this.offlineId,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (table.present) {
      map['table'] = Variable<String>(table.value);
    }
    if (offlineId.present) {
      map['offline_id'] = Variable<String>(offlineId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MirrorRecordsCompanion(')
          ..write('table: $table, ')
          ..write('offlineId: $offlineId, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalDriftDatabase extends GeneratedDatabase {
  _$LocalDriftDatabase(QueryExecutor e) : super(e);
  late final $PatientRecordsTable patientRecords = $PatientRecordsTable(this);
  late final $OpdRegistrationRecordsTable opdRegistrationRecords =
      $OpdRegistrationRecordsTable(this);
  late final $IpdAdmissionRecordsTable ipdAdmissionRecords =
      $IpdAdmissionRecordsTable(this);
  late final $BillingRecordsTable billingRecords = $BillingRecordsTable(this);
  late final $SyncOutboxEntriesTable syncOutboxEntries =
      $SyncOutboxEntriesTable(this);
  late final $SyncCursorRecordsTable syncCursorRecords =
      $SyncCursorRecordsTable(this);
  late final $SyncConflictRecordsTable syncConflictRecords =
      $SyncConflictRecordsTable(this);
  late final $AppMetadataRecordsTable appMetadataRecords =
      $AppMetadataRecordsTable(this);
  late final $MirrorRecordsTable mirrorRecords = $MirrorRecordsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        patientRecords,
        opdRegistrationRecords,
        ipdAdmissionRecords,
        billingRecords,
        syncOutboxEntries,
        syncCursorRecords,
        syncConflictRecords,
        appMetadataRecords,
        mirrorRecords
      ];
}
