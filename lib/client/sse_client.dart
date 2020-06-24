// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:html';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:uuid/uuid.dart';

/// A client for bi-directional sse communcation.
///
/// The client can send any JSON-encodable messages to the server by adding
/// them to the [sink] and listen to messages from the server on the [stream].
class SseClient extends StreamChannelMixin<String> {
  final _incomingController = StreamController<String>();

  final _outgoingController = StreamController<String>();

  final _logger = Logger('SseClient');

  EventSource _eventSource;

  String _serverUrl;

  Timer _errorTimer;

  /// [serverUrl] is the URL under which the server is listening for
  /// incoming bi-directional SSE connections.
  SseClient(String serverUrl) {
    var clientId = Uuid().v1();
    _eventSource =
        EventSource('$serverUrl?sseClientId=$clientId', withCredentials: true);
    _serverUrl = '$serverUrl?sseClientId=$clientId';
    _outgoingController.stream
        .listen(_onOutgoingMessage, onDone: _onOutgoingDone);
    _eventSource.addEventListener('message', _onIncomingMessage);
    _eventSource.addEventListener('control', _onIncomingControlMessage);
    _eventSource.onOpen.listen((_) {
      _errorTimer?.cancel();
    });
    _eventSource.onError.listen((error) {
      if (!(_errorTimer?.isActive ?? false)) {
        // By default the SSE client uses keep-alive.
        // Allow for a retry to connect before giving up.
        _errorTimer = Timer(const Duration(seconds: 5), () {
          _incomingController.addError(error);
          close();
        });
      }
    });

    _startPostingMessages();
  }

  Stream<Event> get onOpen => _eventSource.onOpen;

  /// Add messages to this [StreamSink] to send them to the server.
  ///
  /// The message added to the sink has to be JSON encodable. Messages that fail
  /// to encode will be logged through a [Logger].
  @override
  StreamSink<String> get sink => _outgoingController.sink;

  /// [Stream] of messages sent from the server to this client.
  ///
  /// A message is a decoded JSON object.
  @override
  Stream<String> get stream => _incomingController.stream;

  void close() {
    _eventSource.close();
    _incomingController.close();
    _outgoingController.close();
  }

  void _onIncomingControlMessage(Event message) {
    var data = (message as MessageEvent).data;
    if (data == 'close') {
      close();
    } else {
      throw UnsupportedError('Illegal Control Message "$data"');
    }
  }

  void _onIncomingMessage(Event message) {
    var decoded =
        jsonDecode((message as MessageEvent).data as String) as String;
    _incomingController.add(decoded);
  }

  void _onOutgoingDone() {
    close();
  }

  final _messages = Queue<dynamic>();
  final _messageEvents = StreamController<Null>();

  void _onOutgoingMessage(dynamic message) async {
    _messages.add(message);
    _messageEvents.add(null);
  }

  void _startPostingMessages() async {
    // TODO: We can only use batching if both server + client know about this.
    await for (var _ in _messageEvents.stream) {
      final batch = _messages.toList();
      if (batch.isEmpty) continue;
      _messages.clear();
      try {
        await HttpRequest.request(_serverUrl,
            method: 'POST', sendData: jsonEncode(batch), withCredentials: true);
      } on JsonUnsupportedObjectError catch (e) {
        _logger.warning('Unable to encode outgoing message: $e');
      } on ArgumentError catch (e) {
        _logger.warning('Invalid argument: $e');
      }
    }
  }
}
