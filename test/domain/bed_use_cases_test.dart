/// Tests for the bed use-case gates (Module 11).
///
/// Registration and maintenance need `ward.administer`; allocation and
/// release need `bed.assign`. Occupied beds refuse maintenance, maintenance
/// beds refuse occupants, and patients hold at most one live stay.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/authorization/authorization_policy.dart';
import 'package:nodex_hms/core/authorization/authorization_snapshot.dart';
import 'package:nodex_hms/core/authorization/permission_catalog.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/domain/beds/bed.dart';
import 'package:nodex_hms/domain/beds/bed_repository.dart';
import 'package:nodex_hms/domain/beds/bed_use_cases.dart';

import 'bed_repository_test.dart' show FakeBedStore;

/// Builds a policy holding exactly [permissions].
AuthorizationPolicy policyWith(Set<String> permissions) {
  final DateTime issuedAt = DateTime.now().toUtc();
  return AuthorizationPolicy(
    snapshot: AuthorizationSnapshot(
      snapshotId: 'snapshot-1',
      tenantId: 'tenant-1',
      userId: 'nurse-1',
      deviceId: 'device-1',
      revision: 1,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(const Duration(days: 30)),
      payloadDigest: 'digest',
      roles: const <String>{NodexRoles.nursingStaff},
      permissions: permissions,
      offlinePermissions: permissions,
      facilityIds: const <String>{},
      departmentIds: const <String>{},
      wardIds: const <String>{},
    ),
    connectivity: ConnectivityState.online,
  );
}

void main() {
  late FakeBedStore store;
  late DefaultBedRepository repository;
  late RegisterBedUseCase register;
  late SetBedStatusUseCase setStatus;
  late AssignBedUseCase assign;
  late ReleaseBedUseCase release;
  late TransferBedUseCase transfer;

  const Set<String> admin = <String>{NodexPermissions.wardAdminister};
  const Set<String> assigner = <String>{NodexPermissions.bedAssign};

  setUp(() {
    store = FakeBedStore();
    repository = DefaultBedRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
    register = RegisterBedUseCase(repository: repository);
    setStatus = SetBedStatusUseCase(repository: repository);
    assign = AssignBedUseCase(repository: repository);
    release = ReleaseBedUseCase(repository: repository);
    transfer = TransferBedUseCase(repository: repository);
  });

  Future<Bed> seedBed({String code = 'A-01'}) async {
    final String id = await register.call(
      policy: policyWith(admin),
      tenantId: 'tenant-1',
      wardId: 'ward-1',
      bedCode: code,
      bedType: BedType.general,
    );
    return (await repository.getBed(id))!;
  }

  group('authorization gates', () {
    test('registration requires ward.administer', () {
      expect(
        register.call(
          policy: policyWith(assigner),
          tenantId: 'tenant-1',
          wardId: 'ward-1',
          bedCode: 'A-01',
          bedType: BedType.general,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('allocation and release require bed.assign', () async {
      final Bed bed = await seedBed();
      await expectLater(
        assign.call(
          policy: policyWith(admin),
          bed: bed,
          patientId: 'patient-1',
          assignedBy: 'nurse-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );

      final String stayId = await assign.call(
        policy: policyWith(assigner),
        bed: bed,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      final BedAssignment stay = (await repository.activeAssignmentForBed(
        bed.id,
      ))!;
      expect(stay.id, stayId);
      await expectLater(
        release.call(
          policy: policyWith(admin),
          assignment: stay,
          reason: 'Discharge',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });

  group('allocation rules', () {
    test('maintenance beds refuse occupants', () async {
      Bed bed = await seedBed();
      await setStatus.call(
        policy: policyWith(admin),
        bed: bed,
        status: BedStatus.maintenance,
      );
      bed = (await repository.getBed(bed.id))!;
      await expectLater(
        assign.call(
          policy: policyWith(assigner),
          bed: bed,
          patientId: 'patient-1',
          assignedBy: 'nurse-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('occupied beds and double-held patients refuse', () async {
      final Bed bed = await seedBed();
      final Bed other = await seedBed(code: 'A-02');
      await assign.call(
        policy: policyWith(assigner),
        bed: bed,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      await expectLater(
        assign.call(
          policy: policyWith(assigner),
          bed: bed,
          patientId: 'patient-2',
          assignedBy: 'nurse-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
      await expectLater(
        assign.call(
          policy: policyWith(assigner),
          bed: other,
          patientId: 'patient-1',
          assignedBy: 'nurse-1',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('occupied beds refuse maintenance', () async {
      final Bed bed = await seedBed();
      await assign.call(
        policy: policyWith(assigner),
        bed: bed,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      await expectLater(
        setStatus.call(
          policy: policyWith(admin),
          bed: bed,
          status: BedStatus.maintenance,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('release frees both bed and patient', () async {
      final Bed bed = await seedBed();
      await assign.call(
        policy: policyWith(assigner),
        bed: bed,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      final BedAssignment stay = (await repository.activeAssignmentForBed(
        bed.id,
      ))!;
      await release.call(
        policy: policyWith(assigner),
        assignment: stay,
        reason: 'Discharge home',
      );
      expect(await repository.activeAssignmentForBed(bed.id), isNull);
      expect(await repository.activeAssignmentForPatient('patient-1'), isNull);
    });

    test('transfer releases before allocating', () async {
      final Bed first = await seedBed();
      final Bed second = await seedBed(code: 'A-02');
      await assign.call(
        policy: policyWith(assigner),
        bed: first,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      final BedAssignment stay = (await repository.activeAssignmentForBed(
        first.id,
      ))!;
      final String nextId = await transfer.call(
        policy: policyWith(assigner),
        from: stay,
        toBed: second,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
        reason: 'Isolation required',
      );
      expect(nextId.isNotEmpty, isTrue);
      expect(await repository.activeAssignmentForBed(first.id), isNull);
      expect((await repository.activeAssignmentForBed(second.id))!.id, nextId);
    });

    test('closed stays refuse release', () async {
      final Bed bed = await seedBed();
      await assign.call(
        policy: policyWith(assigner),
        bed: bed,
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );
      final BedAssignment stay = (await repository.activeAssignmentForBed(
        bed.id,
      ))!;
      await release.call(
        policy: policyWith(assigner),
        assignment: stay,
        reason: 'Discharge',
      );
      final BedAssignment closed = (await repository.listAssignmentsForPatient(
        'patient-1',
      )).single;
      await expectLater(
        release.call(
          policy: policyWith(assigner),
          assignment: closed,
          reason: 'Again',
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });
  });
}
