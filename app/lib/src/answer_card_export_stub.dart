import 'answer_card_export.dart';

/// Native printing is unavailable until an Android bridge is implemented.
/// Clipboard text remains supported by the shared Flutter SDK adapter.
AnswerCardPrintReservation? reserveAnswerCardPrintWindow() => null;
