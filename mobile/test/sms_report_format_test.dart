// Scope 2.4 / UC-CD1 alt 11b / UC-A3 alt 8a: the structured SMS format.
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/sms_report_format.dart';
import 'package:mobile/ui/sms_send_screen.dart' show smsUri;

void main() {
  test(
    'What the Disaster Unit sends is read back the same by the Administrator',
    () {
      const sent = SmsReport(
        disasterType: 'Flood',
        barangay: 'Banilad',
        families: 150,
        needs: [
          SmsNeed('Rice', 50, 'kg'),
          SmsNeed('Drinking Water', 20, 'gallons'),
        ],
        details: 'Waist-deep flood near the chapel',
      );
      final text = sent.toMessage();
      expect(text, startsWith(smsReportHeader));
      expect(text, contains('SITIO: Whole barangay'));

      final got = SmsReport.parse(text)!;
      expect(got.disasterType, 'Flood');
      expect(got.barangay, 'Banilad');
      expect(got.sitio, isNull); // whole barangay
      expect(got.families, 150);
      expect(got.needs.length, 2);
      expect(got.needs[1].item, 'Drinking Water');
      expect(got.needs[1].quantity, 20);
      expect(got.needs[1].unit, 'gallons');
      expect(got.details, 'Waist-deep flood near the chapel');
      expect(got.problems, isEmpty);
      expect(got.missing, isEmpty);
    },
  );

  test('Hand-typed text: any order, lowercase, alternative keys', () {
    final got = SmsReport.parse(
      'needs: noodles 20 packs\n'
      'barangay: Casili\n'
      'disaster: typhoon\n'
      'sitio: Sitio Lower\n'
      'affected families: 21 families',
    )!;
    expect(got.disasterType, 'typhoon');
    expect(got.barangay, 'Casili');
    expect(got.sitio, 'Sitio Lower');
    expect(got.families, 21);
    expect(got.needs.single.item, 'noodles');
    expect(got.needs.single.quantity, 20);
  });

  test('Unreadable parts are listed, not silently dropped', () {
    final got = SmsReport.parse(
      'TYPE: Fire\nFAMILIES: many\nNEEDS: Rice; Water 5',
    )!;
    expect(got.families, isNull);
    expect(got.needs.single.item, 'Water');
    expect(got.problems.length, 2); // FAMILIES and "Rice"
    expect(got.missing, containsAll(['barangay', 'number of families']));
  });

  test('A text that is not a NexaAid report returns null', () {
    expect(
      SmsReport.parse(
        'Hello, Im under the water, please help me! here too much raining',
      ),
      isNull,
    );
  });

  test('Line breaks typed inside a field cannot break the format', () {
    const r = SmsReport(
      disasterType: 'Flood',
      barangay: 'Banilad',
      families: 1,
      needs: [SmsNeed('Rice', 1)],
      details: 'line one\nBRGY: Fake',
    );
    expect(SmsReport.parse(r.toMessage())!.barangay, 'Banilad');
  });

  test('problema_napud 2.2: several sitios go through the SMS', () {
    const sent = SmsReport(
      disasterType: 'Flood',
      barangay: 'Banilad',
      sitio: 'Riverside, Proper',
      families: 10,
      needs: [SmsNeed('Rice', 5, 'sacks')],
    );
    expect(sent.toMessage(), contains('SITIO: Riverside, Proper'));
    final got = SmsReport.parse(sent.toMessage())!;
    expect(got.sitios, ['Riverside', 'Proper']);
    expect(
      SmsReport.parse('TYPE: Flood\nSITIO: whole barangay')!.sitios,
      isEmpty,
    );
  });

  test(
    'problema_napud 2.2: the SMS app opens with every number and the text',
    () {
      final uri = smsUri([
        '09171111111',
        '09172222222',
      ], 'NEXAAID REPORT\nTYPE: Flood');
      expect(uri.scheme, 'sms');
      expect(uri.path, '09171111111,09172222222');
      expect(uri.queryParameters['body'], 'NEXAAID REPORT\nTYPE: Flood');
    },
  );
}
