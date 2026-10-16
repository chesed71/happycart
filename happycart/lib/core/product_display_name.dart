/// 앱에 보여 줄 상품명: 이름 끝에 붙은 용량·수량 표기를 뗀다.
///
/// 용량만 다른 바코드는 한 상품(master)으로 묶여 같은 이름을 보여 주므로,
/// 이름 속 용량("80g")이 찍은 바코드의 실제 용량과 다를 수 있다. 그래서 화면에는 용량을 보이지 않는다.
/// - 끝의 "숫자+단위"("120g", "24포", "2,400ml", "3캔입")와 묶음 표시("x 3", "*2입")를 반복해서 뗀다.
/// - 끝의 괄호가 용량·수량만 담고 있으면("(500ML)", "(2.0L*2입)", "(30G(1 5G*20))") 괄호째 뗀다.
/// - 단위 없는 숫자("석류 100", "2X")와 용량이 아닌 괄호("(라임)"), 이름 중간의 용량은 남긴다.
/// - 다 지워지면 원래 이름을 돌려준다.
String productDisplayName(String name) {
  var t = name.trim();
  while (true) {
    final next = _stripOnce(t);
    if (next == t) break;
    t = next;
  }
  return t.isEmpty ? name : t;
}

const _num = r'\d+(?:[.,]\d+)*';
const _unit = r'(?:kg|mg|ml|g|l|ea|매|개|포|봉|팩|병|캔|정|구)입?|입';

// 끝의 "숫자+단위" 또는 묶음 표시 "x 숫자(+단위)".
final _tailQty = RegExp(
  '(?:\\s*[x×*]\\s*$_num\\s*(?:$_unit)?|\\s*$_num\\s*(?:$_unit))\\s*\$',
  caseSensitive: false,
);

// 용량·수량만 담은 괄호 내용(한 단계 중첩 허용).
final _qtyOnly = RegExp(
  '^(?:[\\s()x×*+/,]|$_num|$_unit)+\$',
  caseSensitive: false,
);

String _stripOnce(String t) {
  final s = t.replaceFirst(RegExp(r'[\s,·/]+$'), '');
  if (s.endsWith(')')) {
    final open = _openingParen(s);
    if (open > 0) {
      final inner = s.substring(open + 1, s.length - 1);
      if (RegExp(r'\d').hasMatch(inner) && _qtyOnly.hasMatch(inner)) {
        return s.substring(0, open).trimRight();
      }
    }
    return s;
  }
  return s.replaceFirst(_tailQty, '').trimRight();
}

// 끝의 ')' 와 짝이 맞는 '(' 위치(없으면 -1).
int _openingParen(String s) {
  var depth = 0;
  for (var i = s.length - 1; i >= 0; i--) {
    final c = s[i];
    if (c == ')') depth++;
    if (c == '(') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
