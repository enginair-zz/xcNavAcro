import 'dart:collection';

class _VarioSample {
  /// Milliseconds since epoch at the end of the sample
  final int time;

  /// m/s
  final double rate;

  /// Milliseconds the sample covers
  final int weight;

  const _VarioSample(this.time, this.rate, this.weight);
}

/// Climb rate averaged over the last [window], weighted by the time each sample covers.
///
/// The old 0.8 / 0.2 smoothing per reading was too jumpy to read a climb rate from (about 1 s on the phone
/// barometer). Averaging over a fixed time also behaves the same whatever rate the samples come in at
/// (phone baro ~5 hz, external vario 10 hz, GPS every few seconds).
class VarioAverage {
  Duration window;

  final Queue<_VarioSample> _samples = Queue();
  double _sum = 0;
  int _weight = 0;
  int? _lastTime;

  VarioAverage({this.window = const Duration(seconds: 5)});

  /// m/s. Zero before the first sample.
  double get value => _weight > 0 ? _sum / _weight : 0;

  /// Add a climb rate (m/s) measured up to [timeMs] (milliseconds since epoch). It counts for the time since the
  /// previous sample (at most [window]). Returns the new average.
  double add(int timeMs, double rate) {
    final last = _lastTime;
    if (!rate.isFinite || (last != null && timeMs <= last)) return value;
    _lastTime = timeMs;
    if (last == null) return value; // Nothing to weigh the first sample by
    final weight = (timeMs - last).clamp(1, window.inMilliseconds);
    _samples.add(_VarioSample(timeMs, rate, weight));
    _sum += rate * weight;
    _weight += weight;
    final cutoff = timeMs - window.inMilliseconds;
    while (_samples.length > 1 && _samples.first.time <= cutoff) {
      final old = _samples.removeFirst();
      _sum -= old.rate * old.weight;
      _weight -= old.weight;
    }
    return value;
  }

  /// Start over (the next sample only sets the time).
  void reset() {
    _samples.clear();
    _sum = 0;
    _weight = 0;
    _lastTime = null;
  }

  /// Move on to [timeMs] without counting the time since the previous sample, keeping the average so far. For a step
  /// that isn't a climb or sink, such as switching between barometers.
  void skipTo(int timeMs) {
    if (_lastTime == null || timeMs > _lastTime!) _lastTime = timeMs;
  }
}
