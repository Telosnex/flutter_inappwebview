// Test-only hooks for example/integration_test/review_*_test.dart.
//
// The plugin opens real GTK dialogs (color, date, file) and a custom popup
// menu. Dart cannot reach them, so these hooks find and answer them as a
// user would. They also count live instances of a few WebKit classes to
// observe leaks.
//
// Registered only when FLUTTER_INAPPWEBVIEW_REVIEW_HOOKS=1, so normal runs
// of the example are unchanged.

#ifndef RUNNER_REVIEW_TEST_HOOKS_H_
#define RUNNER_REVIEW_TEST_HOOKS_H_

#include <flutter_linux/flutter_linux.h>

void review_test_hooks_register(FlView* view);

#endif  // RUNNER_REVIEW_TEST_HOOKS_H_
