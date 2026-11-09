import 'package:flutter_test/flutter_test.dart';
import 'package:xcnav/models/vario_average.dart';

void main() {
  group("VarioAverage", () {
    test("zero before samples, first sample only sets the time", () {
      final avg = VarioAverage();
      expect(avg.value, 0);
      expect(avg.add(1000, 3), 0);
      expect(avg.add(1200, 2), 2);
    });

    test("averages over the window, not per reading", () {
      final avg = VarioAverage(window: const Duration(seconds: 5));
      avg.add(0, 0);
      // 4 s of 0, then 1 s of 5 m/s (5 hz)
      for (int t = 200; t <= 4000; t += 200) {
        avg.add(t, 0);
      }
      for (int t = 4200; t <= 5000; t += 200) {
        avg.add(t, 5);
      }
      expect(avg.value, closeTo(1.0, 1e-9));
      // Another 5 s of 5 m/s pushes the zeros out
      for (int t = 5200; t <= 10000; t += 200) {
        avg.add(t, 5);
      }
      expect(avg.value, closeTo(5.0, 1e-9));
    });

    test("weights by time, so sample rate doesn't matter", () {
      final avg = VarioAverage(window: const Duration(seconds: 5));
      avg.add(0, 0);
      avg.add(4000, 1); // one slow sample covering 4 s
      for (int t = 4100; t <= 5000; t += 100) {
        avg.add(t, 6); // 1 s of fast samples
      }
      expect(avg.value, closeTo((4 * 1 + 1 * 6) / 5, 1e-9));
    });

    test("ignores non-finite and out-of-order samples", () {
      final avg = VarioAverage();
      avg.add(0, 0);
      avg.add(1000, 2);
      expect(avg.add(2000, double.nan), 2);
      expect(avg.add(500, 10), 2);
      expect(avg.add(3000, 2), 2);
    });

    test("skipTo doesn't count the step", () {
      final avg = VarioAverage(window: const Duration(seconds: 5));
      avg.add(0, 0);
      avg.add(1000, 1);
      avg.skipTo(1100);
      avg.add(2100, 3);
      expect(avg.value, closeTo(2, 1e-9));
    });

    test("a long gap counts as at most one window", () {
      final avg = VarioAverage(window: const Duration(seconds: 5));
      avg.add(0, 0);
      avg.add(1000, 1);
      avg.add(60000, 4);
      expect(avg.value, closeTo(4, 1e-9));
    });

    test("shorter window drops older samples", () {
      final avg = VarioAverage(window: const Duration(seconds: 15));
      avg.add(0, 0);
      for (int t = 1000; t <= 10000; t += 1000) {
        avg.add(t, 0);
      }
      avg.add(11000, 3);
      avg.window = const Duration(seconds: 2);
      avg.add(12000, 3);
      expect(avg.value, closeTo(3, 1e-9));
    });
  });
}
