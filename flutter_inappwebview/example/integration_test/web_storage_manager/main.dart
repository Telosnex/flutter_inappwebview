import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import '../constants.dart';
import '../util.dart';

part 'remove_data_modified_since.dart';

void main() {
  final shouldSkip = !WebStorageManager.isMethodSupported(
    PlatformWebStorageManagerMethod.removeDataModifiedSince,
  );

  skippableGroup('Web Storage Manager', () {
    removeDataModifiedSince();
  }, skip: shouldSkip);
}
