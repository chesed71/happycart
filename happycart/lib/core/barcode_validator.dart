/// EAN-13 / EAN-8 바코드 체크섬 검증.
///
/// GS1 표준 체크 디지트 알고리즘:
/// - 체크 디지트를 제외한 자릿수를 오른쪽에서 왼쪽으로 읽으며
///   교대로 3과 1의 가중치를 곱해 합산한다.
/// - 그 결과 EAN-13(12+1)은 1,3,1,3,... 순서로,
///   EAN-8(7+1)은 3,1,3,1,... 순서로 가중치가 적용된다.
/// - 체크 디지트는 (10 − sum mod 10) mod 10.
class BarcodeValidator {
  const BarcodeValidator._();

  static bool isValidEan(String code) {
    if (code.length != 8 && code.length != 13) {
      return false;
    }
    final digits = List<int>.filled(code.length, 0);
    for (var i = 0; i < code.length; i++) {
      final unit = code.codeUnitAt(i);
      if (unit < 0x30 || unit > 0x39) {
        return false;
      }
      digits[i] = unit - 0x30;
    }
    final payloadLength = code.length - 1;
    var sum = 0;
    for (var i = 0; i < payloadLength; i++) {
      final fromRight = payloadLength - i;
      final weight = fromRight.isOdd ? 3 : 1;
      sum += digits[i] * weight;
    }
    final expected = (10 - (sum % 10)) % 10;
    return expected == digits[payloadLength];
  }
}
