/// Tests for the discharge entities (Module 23).
///
/// Draft -> finalized discharge per encounter. A finalized discharge is the
/// authorized record of the episode and stays immutable; a readmission is a
/// new encounter with its own discharge.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/discharge/discharge.dart';

void main() {
  group('Discharge.draftRow', () {
    test('builds an editable draft', () {
      final Map<String, Object?> row = Discharge.draftRow(
        tenantId: 'tenant-1',
        patientId: 'patient-1',
        encounterId: 'enc-1',
        createdBy: 'doctor-1',
        dischargeCode: 'D-001',
        dischargeType: DischargeType.routine,
        summary: 'Recovered well.',
      );

      expect(row['status'], DischargeStatus.draft.wireValue);
      expect(row['finalized_by'], isNull);
      final Discharge record = Discharge.fromRow(<String, Object?>{
        ...row,
        'id': 'd-1',
      });
      expect(record.status.isEditable, isTrue);
    });

    test('rejects blank identity with field errors', () {
      try {
        Discharge.draftRow(
          tenantId: '',
          patientId: '',
          encounterId: '',
          createdBy: '',
          dischargeCode: '  ',
          dischargeType: DischargeType.routine,
        );
        fail('expected ValidationError');
      } on ValidationError catch (error) {
        expect(error.code, 'discharge_invalid');
        expect(
          error.fieldErrors.keys,
          containsAll(<String>[
            'tenant_id',
            'patient_id',
            'encounter_id',
            'created_by',
            'discharge_code',
          ]),
        );
      }
    });
  });

  group('transitions', () {
    test('finalize and cancel carry the required payload', () {
      final Map<String, Object?> finalize = Discharge.finalizeChanges(
        finalizerId: 'doctor-1',
      );
      expect(finalize['status'], DischargeStatus.finalized.wireValue);
      expect(finalize['finalized_by'], 'doctor-1');

      final Map<String, Object?> cancel = Discharge.cancelChanges(
        reason: 'Wrong encounter',
      );
      expect(cancel['closure_reason'], 'Wrong encounter');

      expect(
        () => Discharge.cancelChanges(reason: '  '),
        throwsA(isA<ValidationError>()),
      );
    });
  });
}
