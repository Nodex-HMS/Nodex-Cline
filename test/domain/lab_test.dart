/// Tests for Module 17 laboratory domain entities.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/domain/laboratory/lab.dart';

void main() {
  group('LabOrder', () {
    test('builds an ordered row with structured tests', () {
      final Map<String, Object?> row = LabOrder.orderRow(
        tenantId: 'tenant-1',
        patientId: 'patient-1',
        orderedBy: 'doctor-1',
        orderCode: 'LAB-001',
        priority: LabPriority.stat,
        tests: const <LabTestRequest>[
          LabTestRequest(code: 'CBC', name: 'Complete blood count'),
        ],
      );

      expect(row['status'], 'ordered');
      expect(row['priority'], 'stat');
      expect(row['tests'], contains('CBC'));
      expect(row['tests'], contains('Complete blood count'));
      expect(row['signed_at'], isNull);
    });

    test('rejects an order without tests or identity', () {
      expect(
        () => LabOrder.orderRow(
          tenantId: '',
          patientId: '',
          orderedBy: '',
          orderCode: '',
          priority: LabPriority.routine,
          tests: const <LabTestRequest>[],
        ),
        throwsA(
          isA<ValidationError>().having(
            (ValidationError e) => e.fieldErrors.keys,
            'fields',
            containsAll(<String>[
              'tenant_id',
              'patient_id',
              'ordered_by',
              'order_code',
              'tests',
            ]),
          ),
        ),
      );
    });

    test('maps a row and decodes tests', () {
      final LabOrder order = LabOrder.fromRow(const <String, Object?>{
        'id': 'order-1',
        'tenant_id': 'tenant-1',
        'patient_id': 'patient-1',
        'ordered_by': 'doctor-1',
        'order_code': 'LAB-001',
        'priority': 'urgent',
        'status': 'collected',
        'tests': '[{"code":"HB","name":"Hemoglobin"}]',
        'ordered_at': '2026-09-12T10:00:00.000Z',
      });

      expect(order.priority, LabPriority.urgent);
      expect(order.status, LabOrderStatus.collected);
      expect(order.tests.single.code, 'HB');
    });
  });

  group('LabSpecimen', () {
    test('builds pending and collected rows', () {
      final Map<String, Object?> pending = LabSpecimen.pendingRow(
        tenantId: 't',
        labOrderId: 'o',
        accessionBarcode: 'ACC-001',
        specimenType: 'blood',
      );
      expect(pending['status'], 'pending');

      final Map<String, Object?> collected = LabSpecimen.collectChanges(
        collectorId: 'nurse-1',
      );
      expect(collected['status'], 'collected');
      expect(collected['collected_by'], 'nurse-1');
      expect(collected['collected_at'], isNotNull);
    });

    test('rejects missing barcode or specimen type', () {
      expect(
        () => LabSpecimen.pendingRow(
          tenantId: 't',
          labOrderId: 'o',
          accessionBarcode: '',
          specimenType: 'blood',
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('LabResult', () {
    test('requires a text or numeric value', () {
      expect(
        () => LabResult.enteredRow(
          tenantId: 't',
          labOrderId: 'o',
          specimenId: 's',
          analyteCode: 'HB',
          analyteName: 'Hemoglobin',
          enteredBy: 'tech',
        ),
        throwsA(
          isA<ValidationError>().having(
            (ValidationError e) => e.code,
            'code',
            'lab_result_value_required',
          ),
        ),
      );
    });

    test('builds an entered row and verification transition', () {
      final Map<String, Object?> entered = LabResult.enteredRow(
        tenantId: 't',
        labOrderId: 'o',
        specimenId: 's',
        analyteCode: 'HB',
        analyteName: 'Hemoglobin',
        enteredBy: 'tech',
        valueNumeric: 13.2,
        unit: 'g/dL',
      );
      expect(entered['status'], 'entered');
      expect(entered['value_numeric'], 13.2);
      expect(entered['verified_by'], isNull);

      final Map<String, Object?> verified = LabResult.verifyChanges(
        verifierId: 'doctor-1',
      );
      expect(verified['status'], 'verified');
      expect(verified['verified_by'], 'doctor-1');
    });

    test('verified and corrected states are immutable states', () {
      expect(LabResultStatus.entered.isEditable, isTrue);
      expect(LabResultStatus.verified.isEditable, isFalse);
      expect(LabResultStatus.corrected.isEditable, isFalse);
    });

    test('maps a corrected row with correction link and reason', () {
      final LabResult result = LabResult.fromRow(const <String, Object?>{
        'id': 'result-2',
        'tenant_id': 't',
        'lab_order_id': 'o',
        'specimen_id': 's',
        'analyte_code': 'HB',
        'analyte_name': 'Hemoglobin',
        'status': 'corrected',
        'value_text': '12.8',
        'entered_by': 'tech',
        'entered_at': '2026-09-12T10:00:00.000Z',
        'verified_by': 'doctor',
        'verified_at': '2026-09-12T10:05:00.000Z',
        'correction_of': 'result-1',
        'correction_reason': 'Analyzer calibration correction',
      });

      expect(result.status, LabResultStatus.corrected);
      expect(result.correctionOf, 'result-1');
      expect(result.correctionReason, contains('calibration'));
    });
  });
}
