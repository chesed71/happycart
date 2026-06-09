import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('latest lookup_product migration returns image_url', () {
    final sql = File(
      '../supabase/migrations/0010_lookup_product_image_url.sql',
    ).readAsStringSync();

    expect(sql, contains('image_url text'));
    expect(sql, contains('p.image_url'));
    expect(sql, contains('8809990172030'));
    expect(sql, contains('verified_status = \$hc\$verified\$hc\$'));
  });

  test('product image source URL is stored outside lookup_product', () {
    final sql = File(
      '../supabase/migrations/0012_product_image_source_url.sql',
    ).readAsStringSync();

    expect(sql, contains('add column if not exists image_source_url text'));
    expect(sql, contains('thumbnail.coupangcdn.com'));
    expect(sql, contains('not exposed by lookup_product'));
  });
}
