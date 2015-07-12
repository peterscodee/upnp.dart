part of upnp;

class DeviceDiscoverer {
  RawDatagramSocket _socket;
  StreamController<DiscoveredClient> _clientController = new StreamController.broadcast(sync: true);
  NetworkInterface interface;

  Future start() {
    return RawDatagramSocket.bind("0.0.0.0", 0).then((socket) {
      _socket = socket;
      socket.listen((event) {
        switch (event) {
          case RawSocketEvent.READ:
            var packet = socket.receive();
            socket.writeEventsEnabled = true;

            if (packet == null) {
              return;
            }

            var data = UTF8.decode(packet.data);
            var parts = data.split("\r\n");
            parts.removeWhere((x) => x.trim().isEmpty);
            var firstLine = parts.removeAt(0);
            
            if (firstLine.toLowerCase().trim() == "HTTP/1.1 200 OK".toLowerCase()) {
              var headers = {};
              var client =  new DiscoveredClient();

              for (var part in parts) {
                var hp = part.split(":");
                var name = hp[0].trim();
                var value = (hp..removeAt(0)).join(":").trim();
                headers[name.toUpperCase()] = value;
              }

              if (!headers.containsKey("LOCATION")) {
                return;
              }

              client.st = headers["ST"];
              client.usn = headers["USN"];
              client.location = headers["LOCATION"];
              client.server = headers["SERVER"];
              client.headers = headers;
              _clientController.add(client);
            }
            break;
          case RawSocketEvent.WRITE:
            break;
        }
      });

      socket.joinMulticast(new InternetAddress("239.255.255.250"), interface);
    });
  }

  void stop() {
    _socket.close();
  }

  Stream<DiscoveredClient> get clients => _clientController.stream;

  void search([String searchTarget = "upnp:rootdevice"]) {
    var buff = new StringBuffer();

    buff.write("M-SEARCH * HTTP/1.1\r\n");
    buff.write("HOST:239.255.255.250:1900\r\n");
    buff.write('MAN:"ssdp:discover"\r\n');
    buff.write("MX:1\r\n");
    buff.write("ST:${searchTarget}\r\n");
    buff.write("USER-AGENT:unix/5.1 UPnP/1.1 crash/1.0\r\n\r\n");
    var data = UTF8.encode(buff.toString());
    _socket.send(data, new InternetAddress("239.255.255.250"), 1900);
  }

  Future<List<DiscoveredClient>> discoverClients({Duration timeout: const Duration(seconds: 5)}) {
    var completer = new Completer();
    StreamSubscription sub;
    var list = [];
    sub = clients.listen((client) {
      list.add(client);
    });

    var f = new Future.value();

    if (_socket == null) {
      f = start();
    }

    f.then((_) {
      search();
      new Future.delayed(timeout, () {
        sub.cancel();
        stop();
        completer.complete(list);
      });
    });

    return completer.future;
  }

  Future<List<DiscoveredDevice>> discoverDevices({String type, Duration timeout: const Duration(seconds: 5)}) {
    return discoverClients(timeout: timeout).then((clients) {
      if (clients.isEmpty) {
        return [];
      }

      var uuids = clients.where((client) => client.usn != null).map((client) => client.usn.split("::").first).toSet();
      var devices = [];

      for (var uuid in uuids) {
        var deviceClients = clients.where((client) {
          return client != null && client.usn != null && client.usn.split("::").first == uuid;
        }).toList();
        var location = deviceClients.first.location;
        var serviceTypes = deviceClients.map((it) => it.st).toSet().toList();
        var device = new DiscoveredDevice();
        device.serviceTypes = serviceTypes;
        device.uuid = uuid;
        device.location = location;
        if (type == null || serviceTypes.contains(type)) {
          devices.add(device);
        }
      }

      for (var client in clients.where((it) => it.usn == null)) {
        var device = new DiscoveredDevice();
        device.serviceTypes = [client.st];
        device.uuid = null;
        device.location = client.location;
        if (type == null || device.serviceTypes.contains(type)) {
          devices.add(device);
        }
      }

      return devices;
    });
  }

  Future<List<Device>> getDevices({String type, Duration timeout: const Duration(seconds: 5)}) {
    var group = new FutureGroup();
    discoverDevices(type: type, timeout: timeout).then((results) {
      for (var result in results) {
        group.add(result.getRealDevice().catchError((e) {
          if (e is ArgumentError) {
            return null;
          } else {
            throw e;
          }
        }));
      }
    });

    return group.future.then((list) {
      return list.where((it) => it != null).toList();
    });
  }
}

class DiscoveredDevice {
  List<String> serviceTypes = [];
  String uuid;
  String location;

  Future<Device> getRealDevice() {
    return http.get(location).then((response) {
      if (response.statusCode != 200) {
        throw new Exception("ERROR: Failed to fetch device description. Status Code: ${response.statusCode}");
      }

      XmlDocument doc;

      try {
        doc = xml.parse(response.body);
      } on Exception catch (e) {
        throw new FormatException("ERROR: Failed to parse device description. ${e}");
      }

      if (doc.findAllElements("device").isEmpty) {
        throw new ArgumentError("Not SCPD Compatible");
      }

      return new Device.fromXml(location, doc);
    }).timeout(new Duration(seconds: 3), onTimeout: () {
      return null;
    });
  }
}

class DiscoveredClient {
  String st;
  String usn;
  String server;
  String location;
  Map<String, String> headers;

  String toString() {
    var buff = new StringBuffer();
    buff.writeln("ST: ${st}");
    buff.writeln("USN: ${usn}");
    buff.writeln("SERVER: ${server}");
    buff.writeln("LOCATION: ${location}");
    return buff.toString();
  }

  Future<Device> getDevice() {
    return http.get(location).then((response) {
      if (response.statusCode != 200) {
        throw new Exception("ERROR: Failed to fetch device description. Status Code: ${response.statusCode}");
      }

      XmlDocument doc;

      try {
        doc = xml.parse(response.body);
      } on Exception catch (e) {
        throw new FormatException("ERROR: Failed to parse device description. ${e}");
      }

      return new Device.fromXml(location, doc);
    });
  }
}
