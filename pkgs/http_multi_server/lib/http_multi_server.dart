// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';

import 'src/multi_headers.dart';
import 'src/utils.dart';

/// The error code for an error caused by a port already being in use.
final _addressInUseErrno = _computeAddressInUseErrno();
int _computeAddressInUseErrno() {
  if (Platform.isWindows) return 10048;
  if (Platform.isMacOS) return 48;
  assert(Platform.isLinux);
  return 98;
}

/// An implementation of `dart:io`'s [HttpServer] that wraps multiple servers
/// and forwards methods to all of them.
///
/// This is useful for serving the same application on multiple network
/// interfaces while still having a unified way of controlling the servers. In
/// particular, it supports serving on both the IPv4 and IPv6 loopback addresses
/// using [HttpMultiServer.loopback].
class HttpMultiServer extends StreamView<HttpRequest> implements HttpServer {
  /// The wrapped servers.
  final Set<HttpServer> _servers;

  /// Returns the default value of the `Server` header for all responses
  /// generated by each server.
  ///
  /// If the wrapped servers have different default values, it's not defined
  /// which value is returned.
  String get serverHeader => _servers.first.serverHeader;
  set serverHeader(String value) {
    for (var server in _servers) {
      server.serverHeader = value;
    }
  }

  /// Returns the default set of headers added to all response objects.
  ///
  /// If the wrapped servers have different default headers, it's not defined
  /// which header is returned for accessor methods.
  final HttpHeaders defaultResponseHeaders;

  Duration get idleTimeout => _servers.first.idleTimeout;
  set idleTimeout(Duration value) {
    for (var server in _servers) {
      server.idleTimeout = value;
    }
  }

  bool get autoCompress => _servers.first.autoCompress;
  set autoCompress(bool value) {
    for (var server in _servers) {
      server.autoCompress = value;
    }
  }

  /// Returns the port that one of the wrapped servers is listening on.
  ///
  /// If the wrapped servers are listening on different ports, it's not defined
  /// which port is returned.
  int get port => _servers.first.port;

  /// Returns the address that one of the wrapped servers is listening on.
  ///
  /// If the wrapped servers are listening on different addresses, it's not
  /// defined which address is returned.
  InternetAddress get address => _servers.first.address;

  set sessionTimeout(int value) {
    for (var server in _servers) {
      server.sessionTimeout = value;
    }
  }

  /// Creates an [HttpMultiServer] wrapping [servers].
  ///
  /// All [servers] should have the same configuration and none should be
  /// listened to when this is called.
  HttpMultiServer(Iterable<HttpServer> servers)
      : _servers = servers.toSet(),
        defaultResponseHeaders = MultiHeaders(
            servers.map((server) => server.defaultResponseHeaders)),
        super(StreamGroup.merge(servers));

  /// Creates an [HttpServer] listening on all available loopback addresses for
  /// this computer.
  ///
  /// See [HttpServer.bind].
  static Future<HttpServer> loopback(int port,
      {int backlog, bool v6Only = false, bool shared = false}) {
    if (backlog == null) backlog = 0;

    return _loopback(
        port,
        (address, port) => HttpServer.bind(address, port,
            backlog: backlog, v6Only: v6Only, shared: shared));
  }

  /// Like [loopback], but supports HTTPS requests.
  ///
  /// See [HttpServer.bindSecure].
  static Future<HttpServer> loopbackSecure(int port, SecurityContext context,
      {int backlog,
      bool v6Only = false,
      bool requestClientCertificate = false,
      bool shared = false}) {
    if (backlog == null) backlog = 0;

    return _loopback(
        port,
        (address, port) => HttpServer.bindSecure(address, port, context,
            backlog: backlog,
            v6Only: v6Only,
            shared: shared,
            requestClientCertificate: requestClientCertificate));
  }

  /// A helper method for initializing loopback servers.
  ///
  /// [bind] should forward to either [HttpServer.bind] or
  /// [HttpServer.bindSecure].
  static Future<HttpServer> _loopback(
      int port, Future<HttpServer> bind(InternetAddress address, int port),
      [int remainingRetries]) async {
    remainingRetries ??= 5;

    if (!await supportsIPv4) {
      return await bind(InternetAddress.loopbackIPv6, port);
    }

    var v4Server = await bind(InternetAddress.loopbackIPv4, port);
    if (!await supportsIPv6) return v4Server;

    try {
      // Reuse the IPv4 server's port so that if [port] is 0, both servers use
      // the same ephemeral port.
      var v6Server = await bind(InternetAddress.loopbackIPv6, v4Server.port);
      return HttpMultiServer([v4Server, v6Server]);
    } on SocketException catch (error) {
      if (error.osError.errorCode != _addressInUseErrno) rethrow;
      if (port != 0) rethrow;
      if (remainingRetries == 0) rethrow;

      // A port being available on IPv4 doesn't necessarily mean that the same
      // port is available on IPv6. If it's not (which is rare in practice),
      // we try again until we find one that's available on both.
      await v4Server.close();
      return await _loopback(port, bind, remainingRetries - 1);
    }
  }

  Future close({bool force = false}) =>
      Future.wait(_servers.map((server) => server.close(force: force)));

  /// Returns an HttpConnectionsInfo object summarizing the total number of
  /// current connections handled by all the servers.
  HttpConnectionsInfo connectionsInfo() {
    var info = HttpConnectionsInfo();
    for (var server in _servers) {
      var subInfo = server.connectionsInfo();
      info.total += subInfo.total;
      info.active += subInfo.active;
      info.idle += subInfo.idle;
      info.closing += subInfo.closing;
    }
    return info;
  }
}
