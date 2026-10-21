import 'package:integration_test/integration_test.dart';

import 'web_storage_manager/main.dart' as web_storage_manager_tests;

/// Runs only the WebStorageManager tests:
/// `flutter test integration_test/web_storage_manager_test.dart -d windows`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  web_storage_manager_tests.main();
}
