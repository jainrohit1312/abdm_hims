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

abstract class _$LocalDriftDatabase extends GeneratedDatabase {
  _$LocalDriftDatabase(QueryExecutor e) : super(e);
  late final $PatientRecordsTable patientRecords = $PatientRecordsTable(this);
  late final $OpdRegistrationRecordsTable opdRegistrationRecords =
      $OpdRegistrationRecordsTable(this);
  late final $IpdAdmissionRecordsTable ipdAdmissionRecords =
      $IpdAdmissionRecordsTable(this);
  late final $BillingRecordsTable billingRecords = $BillingRecordsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        patientRecords,
        opdRegistrationRecords,
        ipdAdmissionRecords,
        billingRecords
      ];
}
