// Minimal stubs so code using `dart:html`-style APIs compiles on non-web.

class Event {
  void preventDefault() {}
}

class FileUploadInputElement {
  List<File>? files;
  bool multiple = false;
  String accept = '';
  void click() {}
  _Stream<Event> get onChange => _Stream<Event>();
}

class File {
  final String name;
  File(this.name);
}

class FileReader {
  dynamic result;
  void readAsText(File file) {}
  void readAsArrayBuffer(File file) {}
  _Stream<Event> get onLoad => _Stream<Event>();
}

class Blob {
  Blob(List<dynamic> parts);
}

class Url {
  static String createObjectUrl(dynamic obj) => '';
  static void revokeObjectUrl(String url) {}
}

class DocumentBody {
  _Stream<Event> get onDragOver => _Stream<Event>();
  _Stream<Event> get onDragLeave => _Stream<Event>();
  _Stream<Event> get onDrop => _Stream<Event>();
}

class Document {
  DocumentBody? get body => null;
}

// Provide a top-level `document` like dart:html
final Document document = Document();

class _Stream<T> {
  Future<T> get first async => (null as dynamic);
  void listen(void Function(T) handler) {}
}
