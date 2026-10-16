/// 앱에 보여 줄 상품명: 이름 끝에 붙은 용량·수량 표기를 뗀다.
///
/// 용량만 다른 바코드는 한 상품(master)으로 묶여 같은 이름을 보여 주므로,
/// 이름 속 용량("80g")이 찍은 바코드의 실제 용량과 다를 수 있다. 그래서 화면에는 용량을 보이지 않는다.
/// - 끝의 수량식을 통째로 뗀다. 수량식 = 단위가 붙은 숫자("120g", "2,400ml", "3캔입")로 시작하고
///   묶음·더하기("x 3", "*6", "+20g")가 이어질 수 있다. 쉼표로 이어진 수량("70g, 10개")도 차례로 뗀다.
/// - 끝의 괄호가 수량식만 담고 있으면("(500ML)", "(2.0L*2입)", "(30G(1 5G*20))") 괄호째 뗀다.
///   그 뒤에 묶음 표시가 붙어도("(500ML) x 3") 함께 뗀다.
/// - 단위 없는 숫자로 시작하는 것("석류 100", "2X", "(2X)"), 용량이 아닌 괄호("(라임)"), 이름 중간의 용량,
///   끝까지 수량식이 아닌 것("100g+"), 수량식 앞이 연산자로 이어진 것("2 x 500ml", "100g++20g")은 남긴다.
/// - 괄호 짝이 안 맞거나 너무 긴 이름은 손대지 않는다. 다 지워지면 원래 이름을 돌려준다.
String productDisplayName(String name) {
  final trimmed = name.trim();
  if (trimmed.length > _maxLength || !_balanced(trimmed)) return name;
  var t = trimmed;
  while (true) {
    final next = _stripOnce(t);
    if (next == t) break;
    t = next;
  }
  return t.isEmpty ? name : t;
}

// 정규식을 끝에서부터 여러 위치로 맞춰 보므로 길이에 제곱으로 느려질 수 있다 — 상품명은 이보다 짧다.
const _maxLength = 120;

// 반복끼리 겹치지 않게 짠다(숫자 사이 구분자 필수, 반복마다 연산자 필수, 단위 글자는 구분자와 겹치지 않음).
const _num = r'\d+(?:[.,]\d+)*';
// 라벨에 쓰는 유니코드 단위 기호(㎖·ℓ·㎏·㎎·㎗)와 봉지·장·마리·박스·통·인분 포함. 티백 T 는 영문 이름과 헷갈려 넣지 않는다.
const _unit =
    r'(?:(?:kg|mg|ml|g|l|ea|㎖|ℓ|㎏|㎎|㎗|봉지|인분|마리|박스|매|개|포|봉|팩|병|캔|정|구|장|통)입?|입)';
const _expr = '$_num\\s*$_unit(?:\\s*[x×*+]\\s*$_num\\s*$_unit?)*';
// 괄호 안 한 단계 중첩: 숫자·공백·구분자·연산자와 단위만("1 5G*20").
const _inner = '[\\d\\s.,x×*+]*(?:$_unit[\\d\\s.,x×*+]*)*';

final _tailExpr = RegExp('\\s*$_expr\\s*\$', caseSensitive: false);
// 괄호 뒤 묶음 표시("(500ML) x 3" 의 " x 3").
final _tailMultiply = RegExp(
  '\\s*[x×*]\\s*$_num\\s*$_unit?\\s*\$',
  caseSensitive: false,
);
// 지울 수량식 바로 앞이 연산자면 수량식의 일부만 지우게 된다("2 x", "100g++", "500ml x", "(500ml) x").
// 글자 x 는 숫자·숫자+단위·닫는 괄호 뒤일 때만 연산자로 본다("Max" 의 x 는 아님).
final _danglingOperator = RegExp(
  '(?:[×*+]|(?:\\d|\\d\\s*$_unit|\\))\\s*x)\$',
  caseSensitive: false,
);
final _parenExpr = RegExp(
  '^\\s*$_expr\\s*(?:\\($_inner\\))?\\s*\$',
  caseSensitive: false,
);

String _stripOnce(String t) {
  final s = t.replaceFirst(RegExp(r'[\s,·/]+$'), '');
  final multiply = _tailMultiply.firstMatch(s);
  final body = multiply == null
      ? s
      : s.substring(0, multiply.start).trimRight();
  if (body.endsWith(')')) {
    final open = _matchingOpen(body);
    if (open > 0 &&
        _parenExpr.hasMatch(body.substring(open + 1, body.length - 1))) {
      final prefix = body.substring(0, open).trimRight();
      return _danglingOperator.hasMatch(prefix) ? s : prefix;
    }
    if (multiply != null) return s;
  }
  if (s.endsWith(')')) return s;
  final m = _tailExpr.firstMatch(s);
  if (m == null) return s;
  final prefix = s.substring(0, m.start).trimRight();
  return _danglingOperator.hasMatch(prefix) ? s : prefix;
}

// 끝의 ')' 와 짝인 '(' 위치(없으면 -1).
int _matchingOpen(String s) {
  var depth = 0;
  for (var i = s.length - 1; i >= 0; i--) {
    if (s[i] == ')') depth++;
    if (s[i] == '(') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool _balanced(String s) {
  var depth = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')' && --depth < 0) return false;
  }
  return depth == 0;
}
