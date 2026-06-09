-- HappyCart MVP: rule v1.1.0 (refined_sugar 신설) resync.
-- 기존 7건 시드를 DELETE 후 새 verdict 으로 재 INSERT.
-- 변경: 오레오/3분 쇠고기카레/진라면이 okay → not_okay 로 전환 (sugar 매칭).

-- Step 1: 기존 7건 제거.
delete from public.products
where barcode in (
  '8801037088168',  -- 오레오
  '8801047216438',  -- 동원 순참치액
  '8801062516735',  -- 롯데 칸쵸
  '8851103220480',  -- Golden Field 현미유
  '8801052727523',  -- 청정원 곡물100
  '8801045312316',  -- 오뚜기 3분 쇠고기카레
  '8801045522265'   -- 오뚜기 진라면 매운맛
);

-- Step 2: 룰 v1.1.0 으로 재계산된 verdict 으로 재 INSERT.

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801037088168$hc$,
  $hc$오레오$hc$,
  $hc$오레오 (오리지널)$hc$,
  $hc$100g (50g × 2봉지)$hc$,
  $hc$비스킷$hc$,
  $hc$밀가루(밀:미국산,호주산), 설탕, 분당(설탕,옥수수전분), 팜스테아린유(말레이시아산), 야자유, 가공유지(올리브유), 식물성유지(가공유지/팜스테아린유/에스테르화유지(팜스테아린유)), 해바라기유, 혼합제재(올리오레진로즈마리, 폴리글리세린축합리시놀레인산에스테르), 포도당, 옥수수전분, 팜유(말레이시아산) 67%, 정제소금, 코코아분말 33%, 내멸린드스 67%, 정제소금, 팽창제, 향료, 레시틴, 유당, 우유, 바닐린$hc$,
  '{"밀가루","설탕","분당","옥수수전분","팜스테아린유","야자유","가공유지","올리브유","식물성유지","에스테르화유지","해바라기유","올리오레진로즈마리","폴리글리세린축합리시놀레인산에스테르","포도당","팜유","정제소금","코코아분말","팽창제","향료","레시틴","유당","우유","바닐린"}',
  '{"sugar"}',
  '{}',
  '{"refined_sugar"}',
  $hc$not_okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (동서식품)$hc$,
  $hc$http://www.dongsuh.co.kr$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801047216438$hc$,
  $hc$동원$hc$,
  $hc$순참치액$hc$,
  $hc$500g$hc$,
  $hc$액상 조미료$hc$,
  $hc$가다랑어추출물 80% (혼합간장 1.5%, 정제수, 정백당, 정제소금, 가다랑어추출물 5.2%, 참치엑기스, 참치농축액), 참치엑기스 33%, 멸치엑기스 21.54%, 한식간장 4.8% (정제염, 정제소금, 표고버섯추출물), 정백당, 정제염, 양조식초, 표고버섯추출물, 토마토페이스트$hc$,
  '{"가다랑어추출물","혼합간장","정제수","정백당","정제소금","참치엑기스","참치농축액","멸치엑기스","한식간장","정제염","표고버섯추출물","양조식초","토마토페이스트"}',
  '{}',
  '{}',
  '{}',
  $hc$okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (동원F&B)$hc$,
  null,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801062516735$hc$,
  $hc$롯데$hc$,
  $hc$칸쵸 초코$hc$,
  $hc$196g$hc$,
  $hc$초코 비스킷$hc$,
  $hc$밀가루, 정백당, 분당, 콘스타치, 식물성유지(가공유지/말레이시아산 팜유, 야자유), 고과당옥수수시럽(가공유지), 코코아매스 7%, 카라기난, 말토덱스트린, 콜라겐(말레이시아산), 정제소금, 식염, 팽창제, 산미료, 향료, 유화제(대두레시틴), 유당, 분유$hc$,
  '{"밀가루","정백당","분당","콘스타치","식물성유지","가공유지","팜유","야자유","고과당옥수수시럽","코코아매스","카라기난","말토덱스트린","콜라겐","정제소금","식염","팽창제","산미료","향료","유화제","대두레시틴","유당","분유"}',
  '{"carrageenan","hfcs","maltodextrin"}',
  '{}',
  '{"carrageenan","hfcs","maltodextrin"}',
  $hc$not_okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (롯데)$hc$,
  null,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8851103220480$hc$,
  $hc$Golden Field$hc$,
  $hc$Rice Bran Oil (현미유)$hc$,
  $hc$1L$hc$,
  $hc$식용유$hc$,
  $hc$현미유 100% (태국산). Gamma Oryzanol 10,000mg/L, Vitamin E 11.8mg α-TE/100mL.$hc$,
  '{"현미유","rice bran oil"}',
  '{}',
  '{}',
  '{}',
  $hc$okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (AGRO WELLNESS COMPANY LIMITED, 태국)$hc$,
  null,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801052727523$hc$,
  $hc$청정원$hc$,
  $hc$곡물100 (이소말토 올리고당)$hc$,
  $hc$1.2kg$hc$,
  $hc$올리고당/시럽$hc$,
  $hc$옥수수전분 99.5%, 쌀 0.5%. 성분함량: 이소말토올리고당 20g 이상 (100g당/수분제외).$hc$,
  '{"옥수수전분","쌀","이소말토올리고당","올리고당"}',
  '{}',
  '{}',
  '{}',
  $hc$okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (대상 청정원)$hc$,
  $hc$https://www.daesang.com$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801045312316$hc$,
  $hc$오뚜기$hc$,
  $hc$3분 쇠고기카레$hc$,
  $hc$200g$hc$,
  $hc$레토르트식품$hc$,
  $hc$정제수, 감자(미국산: 감자, 산도조절제), 양파퓨레(중국산), 쇠고기(뉴질랜드산), 혼합과일소스, 변성전분, 쇠고기브이용, 설탕, 식물성유지, 카레분, 유크림, 토마토페이스트, 쇠고기다시, 조미양념2, 마늘, 정제소금, 양파맛분말, 후추분, 고춧가루, 강황추출액, 덱스트린$hc$,
  '{"정제수","감자","산도조절제","양파퓨레","쇠고기","혼합과일소스","변성전분","쇠고기브이용","설탕","식물성유지","카레분","유크림","토마토페이스트","쇠고기다시","조미양념2","마늘","정제소금","양파맛분말","후추분","고춧가루","강황추출액","덱스트린"}',
  '{"sugar"}',
  '{}',
  '{"refined_sugar"}',
  $hc$not_okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (오뚜기)$hc$,
  null,
  $hc$2026-05-22T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);

insert into public.products (
  barcode, brand, name, size, category,
  ingredients_raw, ingredients_tokens,
  bad_ingredients_detected, good_ingredients_detected, verdict_reason_codes,
  verdict, rule_version, computed_at,
  source, source_url, source_checked_at, verified_status
) values (
  $hc$8801045522265$hc$,
  $hc$오뚜기$hc$,
  $hc$진라면 매운맛 (5개입)$hc$,
  $hc$600g (120g × 5개입)$hc$,
  $hc$라면$hc$,
  $hc$*면: 소맥분(밀:미국산,호주산), 변성전분, 팜유(말레이시아산), 감자전분(외국산:덴마크,프랑스,독일 등), 글루텐, 정제소금, 마늘시즈닝, 난각분말, 유화유지, 면류첨가알칼리제(산도조절제), 이스트엑기스, 육수추출농축액, 녹차풍미유, 비타민B2. *스프류: 정제소금, 설탕, 포도당, 복합양념분말, 숙성마늘맛분, 간장분말, 볶음양념분말, 육수맛분말, 마늘농축조미분, 고추맛베이스, 로스팅맛분말, 쇠고기육수분말, 조미육수분말, 참맛양념분말, 발효복합분, 진한감칠맛분, 후추분말, 칠리맛분말, 고춧가루, 감칠맛분말, 참맛버섯양념분말, 버섯야채조미분말, 오뚜기참치간장분말, 감칠맛베이스, 로스팅조미분말, 맛베이스, 향미증진제, 볶음마늘분, 육수맛조미분, 육수추출농축분말, 참맛효모조미분말, 숙성양념분말, 칠리추출물, 구아검, 칠리혼합추출물, 산도조절제, 고추농축소스, 조미쇠고기맛후레이크, 건당근, 건청경채, 건파, 건표고버섯, 건고추입자$hc$,
  '{"소맥분","변성전분","팜유","감자전분","글루텐","정제소금","마늘시즈닝","난각분말","유화유지","면류첨가알칼리제","산도조절제","이스트엑기스","육수추출농축액","녹차풍미유","비타민B2","설탕","포도당","복합양념분말","숙성마늘맛분","간장분말","볶음양념분말","육수맛분말","마늘농축조미분","고추맛베이스","로스팅맛분말","쇠고기육수분말","조미육수분말","참맛양념분말","발효복합분","진한감칠맛분","후추분말","칠리맛분말","고춧가루","감칠맛분말","참맛버섯양념분말","버섯야채조미분말","오뚜기참치간장분말","감칠맛베이스","로스팅조미분말","맛베이스","향미증진제","볶음마늘분","육수맛조미분","육수추출농축분말","참맛효모조미분말","숙성양념분말","칠리추출물","구아검","칠리혼합추출물","고추농축소스","조미쇠고기맛후레이크","건당근","건청경채","건파","건표고버섯","건고추입자"}',
  '{"sugar"}',
  '{}',
  '{"refined_sugar"}',
  $hc$not_okay$hc$::public.verdict_enum,
  $hc$v1.1.0$hc$,
  $hc$2026-05-21T00:00:00Z$hc$::timestamptz,
  $hc$제조사 라벨 (오뚜기)$hc$,
  null,
  $hc$2026-05-22T00:00:00Z$hc$::timestamptz,
  $hc$verified$hc$::public.verified_status_enum
);
