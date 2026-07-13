<!-- 
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages). 

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages). 
-->

TODO: Put a short description of the package here that helps potential users
know whether this package might be useful for them.

## Features

TODO: List what your package can do. Maybe include images, gifs, or videos.

## Getting started

TODO: List prerequisites and provide or point to information on how to
start using the package.

## Usage

TODO: Include short and useful examples for package users. Add longer examples
to `/example` folder. 

```dart
const like = 'sample';
```

## Additional information

TODO: Tell users more about the package: where to find more information, how to 
contribute to the package, how to file issues, what response they can expect 
from the package authors, and more.

## 원재료 카탈로그 생성 워크플로

`data/ingredient_catalog.json`이 bad/good 원재료 카탈로그의 단일 진실원(source of
truth)이다. `lib/src/bad_ingredients.g.dart`, `lib/src/good_ingredients.g.dart`는
이 JSON으로부터 생성되는 파일이며 **절대 손으로 편집하지 않는다.**

카탈로그(JSON)를 수정한 뒤에는 항상 아래 명령으로 `.g.dart` 파일을 재생성해야 한다:

```
dart run tool/generate_catalog.dart
```

푸시하기 전에는 `tool/verify_catalog.sh`로 검증한다. 이 스크립트는 재생성 후
diff가 없는지(freshness·멱등), `dart analyze`, `dart test`를 순서대로 확인하고
하나라도 실패하면 non-zero로 종료한다:

```
bash tool/verify_catalog.sh
```

현재 앱 레포에는 `.github/workflows`가 없어 CI가 구성되어 있지 않다. CI가
추가되면 `tool/verify_catalog.sh`를 머지 차단 게이트로 연결해야 한다.
