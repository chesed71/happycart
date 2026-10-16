import 'package:happycart/core/product_display_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('productDisplayName', () {
    test('끝의 용량·수량을 뗀다', () {
      expect(productDisplayName('신라면 120g'), '신라면');
      expect(productDisplayName('WOW 고기열라면 컵 80G'), 'WOW 고기열라면 컵');
      expect(productDisplayName('카누 돌체라떼 24포'), '카누 돌체라떼');
      expect(productDisplayName('생얼음 3kg'), '생얼음');
      expect(productDisplayName('진심 석류100 2,400ml'), '진심 석류100');
      expect(productDisplayName('비타민C 1000mg'), '비타민C');
      expect(productDisplayName('파너유기농착즙당근주스500ml'), '파너유기농착즙당근주스');
    });

    test('묶음 표시와 괄호 속 용량도 뗀다', () {
      expect(productDisplayName('건강한 100살 대추스낵 80g x 3'), '건강한 100살 대추스낵');
      expect(productDisplayName('동원 골뱅이 300 g X 3캔입'), '동원 골뱅이');
      expect(productDisplayName('토레타 (500ML)'), '토레타');
      expect(productDisplayName('코카콜라 (2.0L*2입)'), '코카콜라');
      expect(
        productDisplayName('dmBIO 유기농 굿모닝 허브차 (30G(1 5G*20))'),
        'dmBIO 유기농 굿모닝 허브차',
      );
      expect(productDisplayName('맥심 모카골드 12g x 100개입'), '맥심 모카골드');
    });

    test('용량이 아닌 숫자·괄호는 남긴다', () {
      expect(productDisplayName('진심 석류 100'), '진심 석류 100');
      expect(productDisplayName('불닭볶음면 2X'), '불닭볶음면 2X');
      expect(productDisplayName('펩시 제로 (라임)'), '펩시 제로 (라임)');
      expect(productDisplayName('건강한 100살 대추스낵'), '건강한 100살 대추스낵');
      expect(productDisplayName('7번가 피자 120g 치즈'), '7번가 피자 120g 치즈');
    });

    test('더하기로 이어진 수량식은 통째로, 끝까지 수량식이 아니면 남긴다', () {
      expect(productDisplayName('음료 100g+20g'), '음료');
      expect(productDisplayName('음료 100g+'), '음료 100g+');
      expect(productDisplayName('가나 밀크 초콜릿, 70g, 10개'), '가나 밀크 초콜릿');
    });

    test('괄호 속이라도 단위 없는 숫자로 시작하면 남긴다', () {
      expect(productDisplayName('불닭볶음면 (2X)'), '불닭볶음면 (2X)');
      expect(productDisplayName('펩시 (라임) 500ml'), '펩시 (라임)');
    });

    test('괄호 짝이 안 맞으면 손대지 않는다', () {
      expect(productDisplayName('음료 ((500ml)'), '음료 ((500ml)');
      expect(productDisplayName('음료 (500ml x3'), '음료 (500ml x3');
    });

    test('실패하는 긴 숫자 입력도 빠르게 끝난다', () {
      final sw = Stopwatch()..start();
      for (final k in [20, 40, 100, 5000]) {
        final n = '상품 (${'1' * k}!)';
        expect(productDisplayName(n), n);
        final m = '상품 ${'1.' * k}1g!';
        expect(productDisplayName(m), m);
      }
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('다 지워지면 원래 이름', () {
      expect(productDisplayName('500ml'), '500ml');
      expect(productDisplayName(''), '');
    });
  });
}
