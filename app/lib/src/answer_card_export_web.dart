import 'dart:js_interop';
import 'answer_card_export.dart';

@JS('window.open')
external _BrowserWindow? _open(JSString url, JSString target);
@JS()
extension type _BrowserWindow(JSObject _) implements JSObject {
  external _BrowserDocument get document;
  external bool get closed;
  external set opener(JSAny? value);
  external void addEventListener(JSString type, JSFunction callback);
  external void print();
  external void close();
}
@JS()
extension type _BrowserDocument(JSObject _) implements JSObject {
  external void open();
  external void write(JSString text);
  external void close();
}

class _WebPrintReservation implements AnswerCardPrintReservation {
  _WebPrintReservation(this._window);
  final _BrowserWindow _window;
  @override
  bool get isClosed => _window.closed;
  @override
  void printHtml(String escapedHtml) {
    if (isClosed) throw StateError('Print window was closed');
    _window.document.write(escapedHtml.toJS);
    _window.document.close();
    // document.write can reopen the document, so attach cleanup afterwards.
    _window.addEventListener('afterprint'.toJS, ((JSAny? _) { close(); }).toJS);
    _window.print();
  }
  @override
  void close() {
    if (isClosed) return;
    try {
      _window.document.open();
      _window.document.write('<!doctype html><title></title>'.toJS);
      _window.document.close();
    } finally {
      _window.close();
    }
  }
}

AnswerCardPrintReservation? reserveAnswerCardPrintWindow() {
  final window = _open('about:blank'.toJS, '_blank'.toJS);
  if (window == null) return null;
  try {
    window.opener = null;
    return _WebPrintReservation(window);
  } catch (_) {
    window.close();
    rethrow;
  }
}
