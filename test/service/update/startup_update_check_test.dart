import 'dart:async';

import 'package:anx_reader/service/update/startup_update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent and repeated automatic checks run once per process session', () async {
    final session = StartupUpdateCheck();
    final ready = Completer<void>();
    var requests = 0;
    Future<void> check() async {
      requests++;
      await ready.future;
    }

    final first = session.run(checkForUpdate: check, delay: Duration.zero);
    final second = session.run(checkForUpdate: check, delay: Duration.zero);
    expect(identical(first, second), isTrue);
    ready.complete();
    await first;
    await session.run(checkForUpdate: check, delay: Duration.zero);
    expect(requests, 1);
    await StartupUpdateCheck().run(checkForUpdate: check, delay: Duration.zero);
    expect(requests, 2);
  });

  test('transient startup errors retry at most twice', () async {
    var requests = 0;
    var successes = 0;
    await StartupUpdateCheck().run(
      delay: Duration.zero,
      retryDelays: const [Duration.zero, Duration.zero],
      shouldRetry: (error) => error is TimeoutException,
      checkForUpdate: () async {
        if (++requests < 3) throw TimeoutException('Network unavailable');
        successes++;
      },
    );
    expect(requests, 3);
    expect(successes, 1);
  });

  test('permanent errors are not retried', () async {
    var requests = 0;
    await expectLater(
      StartupUpdateCheck().run(
        delay: Duration.zero,
        retryDelays: const [Duration.zero, Duration.zero],
        shouldRetry: (error) => error is TimeoutException,
        checkForUpdate: () async {
          requests++;
          throw const FormatException('Invalid release');
        },
      ),
      throwsFormatException,
    );
    expect(requests, 1);
  });

  test('exhausted automatic retries do not repeatedly request on route changes', () async {
    final session = StartupUpdateCheck();
    var requests = 0;
    Future<void> check() async {
      requests++;
      throw TimeoutException('Network unavailable');
    }

    final first = session.run(
      checkForUpdate: check,
      delay: Duration.zero,
      retryDelays: const [Duration.zero, Duration.zero],
      shouldRetry: (error) => error is TimeoutException,
    );
    await expectLater(first, throwsA(isA<TimeoutException>()));
    await expectLater(session.run(checkForUpdate: check), throwsA(isA<TimeoutException>()));
    expect(requests, 3);
  });
}
