import 'package:happycart/core/barcode_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BarcodeValidator.isValidEan', () {
    test('valid EAN-13 returns true', () {
      expect(BarcodeValidator.isValidEan('4006381333931'), isTrue);
    });

    test('valid EAN-8 returns true', () {
      expect(BarcodeValidator.isValidEan('73513537'), isTrue);
    });

    test('EAN-13 with one wrong digit returns false', () {
      expect(BarcodeValidator.isValidEan('4006381333932'), isFalse);
    });

    test('13-digit non-numeric string returns false', () {
      expect(BarcodeValidator.isValidEan('400638133393a'), isFalse);
    });

    test('12-digit string returns false', () {
      expect(BarcodeValidator.isValidEan('400638133393'), isFalse);
    });

    test('14-digit string returns false', () {
      expect(BarcodeValidator.isValidEan('40063813339310'), isFalse);
    });

    test('empty string returns false', () {
      expect(BarcodeValidator.isValidEan(''), isFalse);
    });
  });
}
