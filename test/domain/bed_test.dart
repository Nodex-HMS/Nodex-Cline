/// Tests for the bed entities (Module 11).
///
/// Beds carry availability only; occupancy derives from the active assignment.
/// Allocation is server-arbitrated with at most one active assignment per bed
/// and per patient.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/beds/bed.dart';

void main() {
  group('Bed.registerRow', () {
    test('registers an available bed', () {
      final Map<String, Object?> row = Bed.registerRow(
        tenantId: 'tenant-1',
        wardId: 'ward-1',
        bedCode: 'A-01',
        bedType: BedType.icu,
      );

      expect(row['status'], BedStatus.available.wireValue);
      final Bed bed = Bed.fromRow(<String, Object?>{...row, 'id': 'bed-1'});
      expect(bed.bedType, BedType.icu);
    });

    test('rejects blank identity with field errors', () {
      try {
        Bed.registerRow(
          tenantId: '',
          wardId: '',
          bedCode: '  ',
          bedType: BedType.general,
        );
        fail('expected ValidationError');
      } on ValidationError catch (error) {
        expect(error.code, 'bed_invalid');
        expect(
          error.fieldErrors.keys,
          containsAll(<String>['tenant_id', 'ward_id', 'bed_code']),
        );
      }
    });
  });

  group('BedAssignment', () {
    test('assigns active with an admission timestamp', () {
      final Map<String, Object?> row = BedAssignment.assignRow(
        tenantId: 'tenant-1',
        bedId: 'bed-1',
        patientId: 'patient-1',
        assignedBy: 'nurse-1',
      );

      expect(row['status'], BedAssignmentStatus.active.wireValue);
      expect(row['admitted_at'], isNotNull);
      final BedAssignment assignment = BedAssignment.fromRow(<String, Object?>{
        ...row,
        'id': 'stay-1',
      });
      expect(assignment.status.isActive, isTrue);
    });

    test('closing requires a terminal state and a reason', () {
      final Map<String, Object?> released = BedAssignment.closeChanges(
        closure: BedAssignmentStatus.released,
        reason: 'Discharge home',
      );
      expect(released['release_reason'], 'Discharge home');

      expect(
        () => BedAssignment.closeChanges(
          closure: BedAssignmentStatus.active,
          reason: 'x',
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => BedAssignment.closeChanges(
          closure: BedAssignmentStatus.cancelled,
          reason: '  ',
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });
}
