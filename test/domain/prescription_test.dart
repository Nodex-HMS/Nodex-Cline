/// Tests for the prescription entities (Module 25).
///
/// Prescriptions are immutable versioned orders: a finalized order never
/// mutates, a change drafts a successor linked by supersedes, and dispensing
/// plus administration are immutable event rows.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/prescriptions/prescription.dart';

void main() {
  group('Prescription.draftRow', () {
    test('builds a version-1 draft', () {
      final Map<String, Object?> row = Prescription.draftRow(
        tenantId: 'tenant-1',
        patientId: 'patient-1',
        prescribedBy: 'doctor-1',
        prescriptionCode: 'RX-001',
        priority: PrescriptionPriority.routine,
        indication: 'Fever',
      );

      expect(row['status'], PrescriptionStatus.draft.wireValue);
      expect(row['version'], 1);
      expect(row['finalized_by'], isNull);
      expect(row['supersedes'], isNull);
      final Prescription order = Prescription.fromRow(<String, Object?>{
        ...row,
        'id': 'rx-1',
        'created_at': '2026-09-17T00:00:00.000Z',
      });
      expect(order.status.isEditable, isTrue);
      expect(order.version, 1);
    });

    test('rejects blank identity fields with field errors', () {
      try {
        Prescription.draftRow(
          tenantId: '',
          patientId: '',
          prescribedBy: '',
          prescriptionCode: '  ',
          priority: PrescriptionPriority.routine,
        );
        fail('expected ValidationError');
      } on ValidationError catch (error) {
        expect(error.code, 'prescription_invalid');
        expect(
          error.fieldErrors.keys,
          containsAll(<String>[
            'tenant_id',
            'patient_id',
            'prescribed_by',
            'prescription_code',
          ]),
        );
      }
    });
  });

  group('versioning', () {
    Prescription finalized() => Prescription.fromRow(const <String, Object?>{
      'id': 'rx-1',
      'tenant_id': 'tenant-1',
      'patient_id': 'patient-1',
      'prescribed_by': 'doctor-1',
      'prescription_code': 'RX-001',
      'version': 1,
      'priority': 'routine',
      'status': 'finalized',
      'indication': 'Fever',
      'finalized_by': 'doctor-1',
      'finalized_at': '2026-09-17T00:00:00.000Z',
      'created_at': '2026-09-17T00:00:00.000Z',
    });

    test('successor links back and bumps the version', () {
      final Map<String, Object?> row = Prescription.nextVersionRow(
        original: finalized(),
        priority: PrescriptionPriority.urgent,
      );

      expect(row['version'], 2);
      expect(row['supersedes'], 'rx-1');
      expect(row['status'], PrescriptionStatus.draft.wireValue);
    });

    test('a draft cannot receive a new version', () {
      final Prescription draft = Prescription.fromRow(const <String, Object?>{
        'id': 'rx-9',
        'tenant_id': 'tenant-1',
        'patient_id': 'patient-1',
        'prescribed_by': 'doctor-1',
        'prescription_code': 'RX-009',
        'version': 1,
        'priority': 'routine',
        'status': 'draft',
        'created_at': '2026-09-17T00:00:00.000Z',
      });
      expect(
        () => Prescription.nextVersionRow(
          original: draft,
          priority: PrescriptionPriority.routine,
        ),
        throwsA(isA<AuthorizationError>()),
      );
    });

    test('finalize and close transitions carry the required payload', () {
      final Map<String, Object?> finalize = Prescription.finalizeChanges(
        finalizerId: 'doctor-1',
      );
      expect(finalize['status'], PrescriptionStatus.finalized.wireValue);
      expect(finalize['finalized_by'], 'doctor-1');

      final Map<String, Object?> close = Prescription.closeChanges(
        closure: PrescriptionStatus.cancelled,
        reason: 'Duplicate order',
      );
      expect(close['closure_reason'], 'Duplicate order');

      expect(
        () => Prescription.closeChanges(
          closure: PrescriptionStatus.discontinued,
          reason: '  ',
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('parses integer columns stored as text', () {
      final Prescription order = Prescription.fromRow(const <String, Object?>{
        'id': 'rx-1',
        'tenant_id': 'tenant-1',
        'patient_id': 'patient-1',
        'prescribed_by': 'doctor-1',
        'prescription_code': 'RX-001',
        'version': '2',
        'priority': 'stat',
        'status': 'finalized',
        'created_at': '2026-09-17T00:00:00.000Z',
      });
      expect(order.version, 2);
      expect(order.priority, PrescriptionPriority.stat);
    });
  });

  group('PrescriptionItem', () {
    test('draft line requires drug identity, dosage and quantity', () {
      expect(
        () => PrescriptionItem.draftRow(
          tenantId: 'tenant-1',
          prescriptionId: 'rx-1',
          lineNumber: 1,
          drugCode: '',
          drugName: '',
          dosageText: '',
          quantityPrescribed: 0,
        ),
        throwsA(isA<ValidationError>()),
      );
    });

    test('round-trips through a local row', () {
      final Map<String, Object?> row = PrescriptionItem.draftRow(
        tenantId: 'tenant-1',
        prescriptionId: 'rx-1',
        lineNumber: 1,
        drugCode: 'PARA500',
        drugName: 'Paracetamol',
        dosageText: '500mg twice daily',
        quantityPrescribed: 20,
        strength: '500mg',
      );
      final PrescriptionItem item = PrescriptionItem.fromRow(<String, Object?>{
        ...row,
        'id': 'line-1',
      });
      expect(item.lineNumber, 1);
      expect(item.quantityPrescribed, 20);
      expect(item.status, PrescriptionItemStatus.draft);
    });
  });

  group('events', () {
    test('dispense requires identity and positive quantity', () {
      expect(
        () => PharmacyDispense.eventRow(
          tenantId: '',
          prescriptionId: 'rx-1',
          itemId: 'line-1',
          dispensedBy: 'pharm-1',
          quantityDispensed: 10,
        ),
        throwsA(isA<ValidationError>()),
      );
      expect(
        () => PharmacyDispense.eventRow(
          tenantId: 'tenant-1',
          prescriptionId: 'rx-1',
          itemId: 'line-1',
          dispensedBy: 'pharm-1',
          quantityDispensed: 0,
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is ValidationError && e.code == 'dispense_quantity_required',
          ),
        ),
      );
    });

    test('administration requires a recorded dose', () {
      expect(
        () => MedicationAdministration.eventRow(
          tenantId: 'tenant-1',
          patientId: 'patient-1',
          prescriptionId: 'rx-1',
          itemId: 'line-1',
          administeredBy: 'nurse-1',
          doseText: '  ',
        ),
        throwsA(
          predicate(
            (Object e) =>
                e is ValidationError &&
                e.code == 'administration_dose_required',
          ),
        ),
      );
    });
  });
}
