import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum LogLevel {
  none,
  error,
  standard,
  verbose,
}

class FlutterPcmSound {
  static const MethodChannel _channel =
      const MethodChannel('flutter_pcm_sound/methods');

  static Function(int)? onFeedSamplesCallback;

  static LogLevel _logLevel = LogLevel.standard;

  /// set log level
  static Future<void> setLogLevel(LogLevel level) async {
    _logLevel = level;
    return await _invokeMethod('setLogLevel', {'log_level': level.index});
  }

  /// setup audio
  static Future<void> setup({
    required int sampleRate,
    required int channelCount,
    bool iosAllowBackgroundAudio =
        false, // This is still relevant for the native side
  }) async {
    return await _invokeMethod('setup', {
      'sample_rate': sampleRate,
      'num_channels': channelCount,
      'ios_allow_background_audio': iosAllowBackgroundAudio,
    });
  }

  /// queue 16-bit samples (little endian)
  static Future<void> feed(Int16List data) async {
    return await _invokeMethod('feed', {'buffer': data.buffer.asUint8List()});
  }

  /// set the threshold at which we call the
  /// feed callback. i.e. if we have less than X
  /// queued frames, the feed callback will be invoked
  static Future<void> setFeedThreshold(int threshold) async {
    return await _invokeMethod(
        'setFeedThreshold', {'feed_threshold': threshold});
  }

  /// callback is invoked when the audio buffer
  /// is in danger of running out of queued samples
  static void setFeedCallback(Function(int)? callback) {
    onFeedSamplesCallback = callback;
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  /// Starts or resumes the audio engine on the native side.
  /// This will begin the process of the native side calling the feed callback.
  static Future<void> start() async {
    return await _invokeMethod('start');
  }

  /// Stops (pauses) the audio engine on the native side.
  /// This will stop the native side from calling the feed callback, saving resources.
  static Future<void> stop() async {
    return await _invokeMethod('stop');
  }

  /// release all audio resources
  static Future<void> release() async {
    return await _invokeMethod('release');
  }

  static Future<T?> _invokeMethod<T>(String method, [dynamic arguments]) async {
    if (_logLevel.index >= LogLevel.standard.index) {
      String args = '';
      if (method == 'feed') {
        Uint8List data = arguments['buffer'];
        if (data.lengthInBytes > 6) {
          args =
              '(${data.lengthInBytes ~/ 2} samples) ${data.sublist(0, 6)} ...';
        } else {
          args = '(${data.lengthInBytes ~/ 2} samples) $data';
        }
      } else if (arguments != null) {
        args = arguments.toString();
      }
      print("[PCM] invoke: $method $args");
    }
    return await _channel.invokeMethod(method, arguments);
  }

  static Future<dynamic> _methodCallHandler(MethodCall call) async {
    if (_logLevel.index >= LogLevel.standard.index) {
      String func = '[[ ${call.method} ]]';
      String args = call.arguments.toString();
      print("[PCM] $func $args");
    }
    switch (call.method) {
      case 'OnFeedSamples':
        int remainingFrames = call.arguments["remaining_frames"];
        if (onFeedSamplesCallback != null) {
          onFeedSamplesCallback!(remainingFrames);
        }
        break;
      default:
        print('Method not implemented');
    }
  }
}

// for testing
class MajorScale {
  int _periodCount = 0;
  int sampleRate = 44100;
  double noteDuration = 0.25;

  MajorScale({required this.sampleRate, required this.noteDuration});

  // C Major Scale (Just Intonation)
  List<double> get scale {
    List<double> c = [
      261.63,
      294.33,
      327.03,
      348.83,
      392.44,
      436.05,
      490.55,
      523.25
    ];
    return [c[0]] + c + c.reversed.toList().sublist(0, c.length - 1);
  }

  // total periods needed to play the entire note
  int _periodsForNote(double freq) {
    int nFramesPerPeriod = (sampleRate / freq).round();
    int totalFramesForDuration = (noteDuration * sampleRate).round();
    return totalFramesForDuration ~/ nFramesPerPeriod;
  }

  // total periods needed to play the whole scale
  int get _periodsForScale {
    int total = 0;
    for (double freq in scale) {
      total += _periodsForNote(freq);
    }
    return total;
  }

  // what note are we currently playing
  int get noteIdx {
    int accum = 0;
    for (int n = 0; n < scale.length; n++) {
      accum += _periodsForNote(scale[n]);
      if (_periodCount < accum) {
        return n;
      }
    }
    return scale.length - 1;
  }

  // generate a sine wave
  List<int> cosineWave(
      {int periods = 1,
      int sampleRate = 44100,
      double freq = 440,
      double volume = 0.5}) {
    final period = 1.0 / freq;
    final nFramesPerPeriod = (period * sampleRate).toInt();
    final totalFrames = nFramesPerPeriod * periods;
    final step = math.pi * 2 / nFramesPerPeriod;
    List<int> data = List.filled(totalFrames, 0);
    for (int i = 0; i < totalFrames; i++) {
      data[i] =
          (math.cos(step * (i % nFramesPerPeriod)) * volume * 32768).toInt() -
              16384;
    }
    return data;
  }

  void reset() {
    _periodCount = 0;
  }

  // generate the next X periods of the major scale
  List<int> generate({required int periods, double volume = 0.5}) {
    List<int> frames = [];
    for (int i = 0; i < periods; i++) {
      _periodCount %= _periodsForScale;
      frames += cosineWave(
          periods: 1,
          sampleRate: sampleRate,
          freq: scale[noteIdx],
          volume: volume);
      _periodCount++;
    }
    return frames;
  }
}
