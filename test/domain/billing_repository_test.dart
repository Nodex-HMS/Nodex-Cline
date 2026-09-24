/// Tests for the billing repository over a fake local store.
///
/// Mirrors the discharge repository tests: the SQL surface is faked with just
/// enough understanding for the repository's queries. Module 31 shipped without
/// this file, which is part of why three wiring defects (missing local tables,
/// missing sync buckets, an offline-only boolean cast) reached a pushed commit.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nodex_hms/core/errors/nodex_error.dart';
import 'package:nodex_hms/core/logging/nodex_logger.dart';
import 'package:nodex_hms/core/storage/local_schema.dart';
import 'package:nodex_hms/domain/billing/billing_repository.dart';
import 'package:nodex_hms/domain/billing/invoice.dart';
import 'package:nodex_hms/domain/patients/patient_repository.dart';

/// In-memory [PatientLocalStore] extended with the four billing tables.
final class FakeBillingStore implements PatientLocalStore {
  final Map<String, Map<String, Map<String, Object?>>> tables =
      <String, Map<String, Map<String, Object?>>>{};

  /// When true, every operation throws to simulate a closed database.
  bool closed = false;

  Map<String, Map<String, Object?>> _table(String name) =>
      tables.putIfAbsent(name, () => <String, Map<String, Object?>>{});

  void _guard() {
    if (closed) {
      throw const PersistenceError(
        message: 'The local clinical database has not been opened.',
        code: 'database_not_open',
      );
    }
  }

  List<Map<String, Object?>> _matching(
    String table,
    bool Function(Map<String, Object?> row) test,
    int Function(Map<String, Object?> a, Map<String, Object?> b) compare,
  ) => _table(table).values.where(test).toList()..sort(compare);

  @override
  Future<List<Map<String, Object?>>> query(
    String sql,
    List<Object?> parameters,
  ) async {
    _guard();

    if (sql.contains(LocalTables.invoiceLines)) {
      return _matching(
        LocalTables.invoiceLines,
        (Map<String, Object?> r) => r['invoice_id'] == parameters[0],
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['line_number']! as int).compareTo(b['line_number']! as int),
      );
    }
    if (sql.contains(LocalTables.payments)) {
      return _matching(
        LocalTables.payments,
        (Map<String, Object?> r) => r['invoice_id'] == parameters[0],
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['paid_at']! as String).compareTo(b['paid_at']! as String),
      );
    }
    if (sql.contains(LocalTables.refunds)) {
      return _matching(
        LocalTables.refunds,
        (Map<String, Object?> r) => r['invoice_id'] == parameters[0],
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (a['refunded_at']! as String).compareTo(
              b['refunded_at']! as String,
            ),
      );
    }
    if (sql.contains(LocalTables.invoices)) {
      final String column = sql.contains('invoice_code = ?')
          ? 'invoice_code'
          : 'patient_id';
      return _matching(
        LocalTables.invoices,
        (Map<String, Object?> r) => r[column] == parameters[0],
        (Map<String, Object?> a, Map<String, Object?> b) =>
            (b['created_at']! as String).compareTo(a['created_at']! as String),
      );
    }
    throw UnimplementedError('FakeBillingStore cannot run: $sql');
  }

  @override
  Future<Map<String, Object?>?> getById(String table, String id) async {
    _guard();
    return _table(table)[id];
  }

  @override
  Future<void> insert(String table, Map<String, Object?> row) async {
    _guard();
    _table(table)[row['id']! as String] = Map<String, Object?>.from(row);
  }

  @override
  Future<void> update(
    String table,
    String id,
    Map<String, Object?> changes,
  ) async {
    _guard();
    final Map<String, Object?>? existing = _table(table)[id];
    if (existing == null) {
      throw StateError('row $id not found in $table');
    }
    _table(table)[id] = <String, Object?>{...existing, ...changes};
  }
}

void main() {
  late FakeBillingStore store;
  late DefaultBillingRepository repository;

  setUp(() {
    store = FakeBillingStore();
    repository = DefaultBillingRepository(
      store: store,
      logger: NodexLogger(
        sinks: <NodexLogSink>[InMemoryLogSink()],
        minimumLevel: NodexLogLevel.trace,
      ),
    );
  });

  Future<String> seedInvoice({String patientId = 'patient-1'}) =>
      repository.createInvoice(
        Invoice.draftRow(
          tenantId: 'tenant-1',
          patientId: patientId,
          createdBy: 'clerk-1',
          invoiceCode: 'INV-001',
        ),
      );

  group('invoices', () {
    test('creates a draft that lists for its patient', () async {
      final String id = await seedInvoice();

      final List<Invoice> invoices = await repository.listForPatient(
        'patient-1',
      );
      expect(invoices.map((Invoice i) => i.id), contains(id));
      expect(invoices.single.status, InvoiceStatus.draft);
      expect(invoices.single.totalMinor, 0);
      expect(invoices.single.patientId, 'patient-1');
    });

    test('lists nothing for another patient', () async {
      await seedInvoice();
      expect(await repository.listForPatient('patient-9'), isEmpty);
    });

    test('getInvoice returns null when absent', () async {
      expect(await repository.getInvoice('missing'), isNull);
    });

    test('getByCode matches the code exactly', () async {
      final String id = await seedInvoice();
      expect((await repository.getByCode('INV-001'))!.id, id);
      expect(await repository.getByCode('INV-00'), isNull);
    });

    test('an issue transition is persisted in place', () async {
      final String id = await seedInvoice();
      await repository.updateInvoice(id, Invoice.issueChanges());

      final Invoice invoice = (await repository.getInvoice(id))!;
      expect(invoice.status, InvoiceStatus.issued);
      expect(invoice.issuedAt, isNotNull);
    });
  });

  group('invoice lines', () {
    test('lines come back in line order', () async {
      final String invoiceId = await seedInvoice();
      for (final int lineNumber in <int>[2, 1]) {
        await repository.addLine(
          InvoiceLine.draftRow(
            tenantId: 'tenant-1',
            invoiceId: invoiceId,
            lineNumber: lineNumber,
            description: 'Consultation $lineNumber',
            quantity: 1,
            unitPriceMinor: 50000,
            lineTotalMinor: 50000,
          ),
        );
      }

      final List<InvoiceLine> lines = await repository.listLines(invoiceId);
      expect(lines.map((InvoiceLine l) => l.lineNumber), <int>[1, 2]);
      expect(lines.first.lineTotalMinor, 50000);
    });

    test('lines of another invoice are not returned', () async {
      final String invoiceId = await seedInvoice();
      expect(await repository.listLines('$invoiceId-other'), isEmpty);
    });
  });

  group('payments and refunds', () {
    test('a payment carries no client-supplied running total', () async {
      final String invoiceId = await seedInvoice();
      final String paymentId = await repository.recordPayment(
        Payment.eventRow(
          tenantId: 'tenant-1',
          invoiceId: invoiceId,
          recordedBy: 'cashier-1',
          amountMinor: 20000,
          method: PaymentMethod.cash,
        ),
      );

      final List<Payment> payments = await repository.listPayments(invoiceId);
      expect(payments.single.id, paymentId);
      expect(payments.single.amountMinor, 20000);
      // The running total is a server-derived fact: the device must never store
      // its own and present it as authoritative.
      expect(payments.single.amountReceivedMinor, isNull);
    });

    test('payments come back oldest first', () async {
      final String invoiceId = await seedInvoice();
      for (final int amount in <int>[20000, 30000]) {
        await repository.recordPayment(
          Payment.eventRow(
            tenantId: 'tenant-1',
            invoiceId: invoiceId,
            recordedBy: 'cashier-1',
            amountMinor: amount,
            method: PaymentMethod.mobileMoney,
          ),
        );
      }

      final List<Payment> payments = await repository.listPayments(invoiceId);
      expect(payments.map((Payment p) => p.amountMinor), <int>[20000, 30000]);
    });

    test('a refund stays linked to the payment it reverses', () async {
      final String invoiceId = await seedInvoice();
      final String paymentId = await repository.recordPayment(
        Payment.eventRow(
          tenantId: 'tenant-1',
          invoiceId: invoiceId,
          recordedBy: 'cashier-1',
          amountMinor: 20000,
          method: PaymentMethod.cash,
        ),
      );
      await repository.recordRefund(
        Refund.eventRow(
          tenantId: 'tenant-1',
          invoiceId: invoiceId,
          paymentId: paymentId,
          recordedBy: 'cashier-1',
          amountMinor: 5000,
          reason: 'Overpayment returned',
        ),
      );

      final List<Refund> refunds = await repository.listRefunds(invoiceId);
      expect(refunds.single.paymentId, paymentId);
      expect(refunds.single.amountMinor, 5000);
      expect(refunds.single.reason, 'Overpayment returned');
    });

    test('a zero payment is refused before it reaches the store', () {
      expect(
        () => Payment.eventRow(
          tenantId: 'tenant-1',
          invoiceId: 'invoice-1',
          recordedBy: 'cashier-1',
          amountMinor: 0,
          method: PaymentMethod.cash,
        ),
        throwsA(isA<ValidationError>()),
      );
    });
  });

  group('failures', () {
    test('a closed store surfaces PersistenceError on read', () async {
      store.closed = true;
      await expectLater(
        repository.listForPatient('patient-1'),
        throwsA(isA<PersistenceError>()),
      );
    });

    test('a closed store surfaces PersistenceError on write', () async {
      store.closed = true;
      await expectLater(seedInvoice(), throwsA(isA<PersistenceError>()));
    });
  });
}
