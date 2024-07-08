// Copyright (c) 2018, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart';
import 'package:meta/meta.dart';

import '../../client/call.dart';
import '../../shared/message.dart';
import '../../shared/status.dart';
import '../connection.dart';
import 'cors.dart' as cors;
import 'transport.dart';
import 'web_streams.dart';

const _contentTypeKey = 'Content-Type';

class XhrTransportStream implements GrpcTransportStream {
  final BrowserClient _client;
  final Map<String, String> headers;
  final Uri uri;
  final ErrorHandler _onError;

  final Function(XhrTransportStream stream) _onDone;
  final StreamController<ByteBuffer> _incomingProcessor = StreamController();
  final StreamController<GrpcMessage> _incomingMessages = StreamController();
  final StreamController<List<int>> _outgoingMessages = StreamController();

  @override
  Stream<GrpcMessage> get incomingMessages => _incomingMessages.stream;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  XhrTransportStream(
    this._client,
    this.headers,
    this.uri, {
    required ErrorHandler onError,
    required onDone,
  })  : _onError = onError,
        _onDone = onDone {
    _outgoingMessages.stream.map(frame).listen(
      (data) {
        final request = Request('POST', uri);
        request.headers.addAll(headers);
        request.bodyBytes = data;
        _client.send(request).then(
          (streamedResponse) async {
            Response.fromStream(streamedResponse).then(
              (response) {
                _incomingMessages.add(GrpcMetadata(response.headers));
                final valid = _validateResponseState(
                  response.statusCode,
                  response.headers,
                  rawResponse: response.body,
                );
                if (valid) {
                  if (!_incomingProcessor.isClosed) {
                    _incomingProcessor.add(response.bodyBytes.buffer);
                    _incomingProcessor.stream
                        .transform(GrpcWebDecoder())
                        .transform(grpcDecompressor())
                        .listen(
                      (data) {
                        _incomingMessages.add(data);
                      },
                      onError: _onError,
                      onDone: _incomingMessages.close,
                    );
                  }
                }
                _close();
              },
            );
          },
          onError: (_) {
            if (_incomingProcessor.isClosed) {
              return;
            }
            _onError(
              GrpcError.unavailable('XhrConnection connection-error'),
              StackTrace.current,
            );
            terminate();
          },
        );
      },
      cancelOnError: true,
    );
  }

  bool _validateResponseState(
    int? httpStatus,
    Map<String, String> headers, {
    Object? rawResponse,
  }) {
    try {
      validateHttpStatusAndContentType(
        httpStatus,
        headers,
        rawResponse: rawResponse,
      );
      return true;
    } catch (e, st) {
      _onError(e, st);
      return false;
    }
  }

  void _close() {
    _incomingProcessor.close();
    _outgoingMessages.close();
    _onDone(this);
  }

  @override
  Future<void> terminate() async {
    _close();
    _client.close();
  }
}

class XhrClientConnection implements ClientConnection {
  final Uri uri;

  final _requests = <XhrTransportStream>{};

  XhrClientConnection(this.uri);

  @visibleForTesting
  XhrTransportStream get latestRequest => _requests.last;

  @override
  String get authority => uri.authority;

  @override
  String get scheme => uri.scheme;

  @override
  GrpcTransportStream makeRequest(
    String path,
    Duration? timeout,
    Map<String, String> metadata,
    ErrorHandler onError, {
    CallOptions? callOptions,
  }) {
    // gRPC-web headers.
    if (_getContentTypeHeader(metadata) == null) {
      metadata['Content-Type'] = 'application/grpc-web+proto';
      metadata['X-User-Agent'] = 'grpc-web-dart/0.1';
      metadata['X-Grpc-Web'] = '1';
    }

    var requestUri = uri.resolve(path);
    if (callOptions is WebCallOptions &&
        callOptions.bypassCorsPreflight == true) {
      requestUri = cors.moveHttpHeadersToQueryParam(metadata, requestUri);
    }

    final client = BrowserClient();
    if (callOptions is WebCallOptions && callOptions.withCredentials == true) {
      client.withCredentials = true;
    }
    // Must set headers after calling open().
    final transportStream = XhrTransportStream(
      client,
      metadata,
      requestUri,
      onError: onError,
      onDone: _removeStream,
    );
    _requests.add(transportStream);
    return transportStream;
  }

  void _removeStream(XhrTransportStream stream) {
    _requests.remove(stream);
  }

  @override
  Future<void> terminate() async {
    for (final request in List.of(_requests)) {
      request.terminate();
    }
  }

  @override
  void dispatchCall(ClientCall call) {
    call.onConnectionReady(this);
  }

  @override
  Future<void> shutdown() async {}

  @override
  set onStateChanged(void Function(ConnectionState) cb) {
    // Do nothing.
  }
}

MapEntry<String, String>? _getContentTypeHeader(Map<String, String> metadata) {
  for (final entry in metadata.entries) {
    if (entry.key.toLowerCase() == _contentTypeKey.toLowerCase()) {
      return entry;
    }
  }
  return null;
}
