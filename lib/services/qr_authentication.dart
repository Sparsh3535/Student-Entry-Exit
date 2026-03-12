import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Handles TCP server for receiving QR authentication data on port 9000
class QrAuthenticationService {
  ServerSocket? _server;
  bool _listening = false;
  int _port = 9000;

  // Callbacks
  final Function(String) onLog;
  final Function(Map<String, dynamic>) onDataReceived;

  QrAuthenticationService({required this.onLog, required this.onDataReceived});

  bool get isListening => _listening;
  int get port => _port;

  /// Start the TCP server on the specified port
  Future<void> startServer(int port) async {
    if (_listening) return;
    _port = port;

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      _listening = true;
      onLog('Server bound to ${_server!.address.address}:${_server!.port}');

      _server!.listen(
        _handleClient,
        onError: (e) {
          onLog('Server error: $e');
        },
        onDone: () {
          onLog('Server closed');
        },
      );
    } catch (e) {
      onLog('Failed to bind server on port $_port: $e');
      rethrow;
    }
  }

  /// Stop the TCP server
  Future<void> stopServer() async {
    if (!_listening) return;
    try {
      await _server?.close();
      onLog('Server closed manually');
    } catch (e) {
      onLog('Error closing server: $e');
    }
    _server = null;
    _listening = false;
  }

  /// Handle incoming client connections
  void _handleClient(Socket client) {
    onLog(
      'Client connected: ${client.remoteAddress.address}:${client.remotePort}',
    );
    String buffer = '';

    client.listen(
      (List<int> data) {
        final snippet = utf8.decode(
          data.length <= 200 ? data : data.sublist(0, 200),
          allowMalformed: true,
        );
        onLog("Raw chunk bytes=${data.length}");
        final chunk = utf8.decode(data, allowMalformed: true);
        buffer += chunk;

        _processBuffer(
          bufferHolder: () => buffer,
          bufferSetter: (s) => buffer = s,
        );
      },
      onDone: () {
        onLog('Client disconnected: ${client.remoteAddress.address}');
        if (buffer.trim().isNotEmpty) {
          _processLine(buffer.trim());
          buffer = '';
        }
      },
      onError: (e) {
        onLog('Client read error: $e');
      },
      cancelOnError: true,
    );
  }

  /// Process incoming data buffer
  void _processBuffer({
    required String Function() bufferHolder,
    required void Function(String) bufferSetter,
  }) {
    String buf = bufferHolder();
    while (buf.isNotEmpty) {
      final nlIndex = buf.indexOf('\n');
      if (nlIndex >= 0) {
        final line = buf.substring(0, nlIndex).trim();
        if (line.isNotEmpty) _processLine(line);
        buf = buf.substring(nlIndex + 1);
        continue;
      }
      final firstNonWs = _firstNonWhitespaceIndex(buf);
      if (firstNonWs < 0) {
        buf = '';
        break;
      }
      final startChar = buf[firstNonWs];
      if (startChar == '{' || startChar == '[') {
        final endIndex = _findJsonEnd(buf, firstNonWs);
        if (endIndex >= 0) {
          final jsonStr = buf.substring(firstNonWs, endIndex + 1);
          _processLine(jsonStr);
          buf = buf.substring(endIndex + 1);
          continue;
        }
        break;
      }
      _processLine(buf.trim());
      buf = '';
      break;
    }
    bufferSetter(buf);
  }

  /// Find the first non-whitespace character
  int _firstNonWhitespaceIndex(String s) {
    for (var i = 0; i < s.length; i++) {
      if (s[i].trim().isNotEmpty) return i;
    }
    return -1;
  }

  /// Find the end of a JSON string
  int _findJsonEnd(String s, int start) {
    final openChar = s[start];
    final closeChar = (openChar == '{') ? '}' : ']';
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      } else {
        if (ch == '"') {
          inString = true;
          continue;
        }
        if (ch == openChar) {
          depth++;
        } else if (ch == closeChar) {
          depth--;
          if (depth == 0) return i;
        }
      }
    }
    return -1;
  }

  /// Process a complete line of data
  void _processLine(String line) {
    if (line.isEmpty) return;
    onLog('Processing line (${line.length} chars)');
    try {
      final decoded = jsonDecode(line);
      if (decoded is List) {
        for (final e in decoded) {
          _processReceived(e);
        }
      } else {
        _processReceived(decoded);
      }
      onLog('Parsed JSON successfully');
    } catch (e) {
      _processReceived({'raw': line});
      onLog('Failed JSON parse — stored raw');
    }
  }

  /// Process received data and invoke callback
  void _processReceived(dynamic obj) {
    Map<String, dynamic> data;
    if (obj is Map<String, dynamic>) {
      data = Map<String, dynamic>.from(obj);
    } else {
      data = {'value': obj?.toString()};
    }
    onDataReceived(data);
  }

  /// Parse key:value block from dynamic source
  static Map<String, String> parseKeyValueBlock(dynamic src) {
    final Map<String, String> out = {};
    String? s;
    if (src == null) return out;
    if (src is String) {
      s = src;
    } else if (src is Map) {
      final hasNonValueKeys = src.keys.any(
        (k) => k.toString().toLowerCase() != 'value',
      );
      if (hasNonValueKeys) {
        src.forEach((k, v) {
          out[k.toString().toLowerCase()] = v?.toString() ?? '';
        });
        return out;
      }
      if (src.containsKey('value') && src['value'] is String) {
        s = src['value'] as String;
      }
    }
    if (s == null) return out;
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final m = RegExp(r'^\s*([^:]+)\s*:\s*(.+)$').firstMatch(line);
      if (m != null) {
        out[m.group(1)!.trim().toLowerCase()] = m.group(2)!.trim();
      }
    }
    return out;
  }

  /// Helper to get string safely from map
  static String? firstString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      if (m.containsKey(k) && m[k] != null) {
        final v = m[k];
        return v is String ? v : v.toString();
      }
    }
    return null;
  }

  /// Format datetime as short string
  static String shortDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}
