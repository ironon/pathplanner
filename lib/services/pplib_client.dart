import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pathplanner/services/generator/trajectory.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PPLibClient {
  static Socket? _socket;
  static bool _enabled = false;
  static DateTime _lastPong = DateTime.now();
  static ValueChanged<List<Point>>? _onActivePathChanged;
  static Function(TrajectoryState, TrajectoryState)?
      _onPathFollowingDataChanged;

  static Stream<bool> connectionStatusStream() async* {
    bool connected = _socket != null;
    yield connected;

    while (true) {
      bool isConnected = _socket != null;
      if (connected != isConnected) {
        connected = isConnected;
        yield connected;
      }
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  static void setOnActivePathChanged(ValueChanged<List<Point>> onChanged) {
    _onActivePathChanged = onChanged;
  }

  static void setOnPathFollowingDataChanged(
      Function(TrajectoryState, TrajectoryState) onChanged) {
    _onPathFollowingDataChanged = onChanged;
  }

  static Future<void> initialize(SharedPreferences prefs) async {
    String host = prefs.getString('pplibClientHost') ?? '10.30.15.2';
    int port = prefs.getInt('pplibClientPort') ?? 5810;
    _enabled = true;

    try {
      _socket = await Socket.connect(host, port);
    } catch (e) {
      // Connection refused. Wait a few seconds and try again
      await Future.delayed(const Duration(seconds: 10));
      if (_enabled) initialize(prefs);
      return;
    }
    _lastPong = DateTime.now();

    _socket!.listen(
      (Uint8List data) {
        String str = String.fromCharCodes(data).trim();
        List<String> messages = str.split('\n');

        // Dart sockets can group multiple messages together
        for (String message in messages) {
          String msg = message.trim();

          if (msg == 'pong') {
            _lastPong = DateTime.now();
          } else {
            // Commands are sent in JSON format
            Map<String, dynamic> json = jsonDecode(msg);

            String command = json['command'];
            switch (command) {
              case 'activePath':
                {
                  List<Point> activePath = [];
                  for (List<dynamic> state in json['states']) {
                    activePath.add(Point(state[0], state[1]));
                  }

                  if (_onActivePathChanged != null) {
                    _onActivePathChanged!(activePath);
                  }
                }
                break;
              case 'pathFollowingData':
                {
                  // Cheat and use the TrajectoryState class to represent a pose
                  TrajectoryState target = TrajectoryState();
                  target.translationMeters =
                      Point(json['targetPose']['x'], json['targetPose']['y']);
                  target.headingRadians = json['targetPose']['theta'];

                  TrajectoryState actual = TrajectoryState();
                  actual.translationMeters =
                      Point(json['actualPose']['x'], json['actualPose']['y']);
                  actual.headingRadians = json['actualPose']['theta'];

                  if (_onPathFollowingDataChanged != null) {
                    _onPathFollowingDataChanged!(target, actual);
                  }
                }
                break;
              default:
                {
                  // Unknown command
                }
                break;
            }
          }
        }
      },
      onError: (error) {
        print('Server connection error');
      },
      onDone: () {
        if (_socket != null) {
          _socket!.destroy();
          _socket = null;
        }

        // Attempt to reconnect.
        if (_enabled) initialize(prefs);
      },
    );

    // Send a 'ping' message to the server every 2 seconds so both ends
    // know the connection is still alive
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_socket == null) {
        timer.cancel();
        return;
      }

      if (DateTime.now().difference(_lastPong).inSeconds > 10) {
        // Connection with server timed out
        _socket!.destroy();
        timer.cancel();
        return;
      }

      _socket!.writeln('ping');
    });
  }

  static void stopServer() {
    if (_enabled) {
      _enabled = false;
      if (_socket != null) {
        _socket!.destroy();
      }
    }
  }
}
