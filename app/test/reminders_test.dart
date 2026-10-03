import 'package:anxin_companion/src/reminders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('moves check-ins out of overnight quiet hours', () {
    final afterQuietHours = calculateCheckInDateTime(
      DateTime(2026, 9, 28, 7),
      const TimeOfDay(hour: 7, minute: 30),
      weekly: false,
      weekday: 1,
      afterInteraction: false,
    );
    expect(afterQuietHours, DateTime(2026, 9, 28, 9));

    final nextMorning = calculateCheckInDateTime(
      DateTime(2026, 9, 28, 22),
      const TimeOfDay(hour: 23, minute: 0),
      weekly: false,
      weekday: 1,
      afterInteraction: false,
    );
    expect(nextMorning, DateTime(2026, 9, 29, 9));
  });

  test('defers a daily check-in until tomorrow after a conversation', () {
    expect(
      calculateCheckInDateTime(
        DateTime(2026, 9, 28, 8),
        const TimeOfDay(hour: 10, minute: 0),
        weekly: false,
        weekday: 1,
        afterInteraction: true,
      ),
      DateTime(2026, 9, 29, 10),
    );
  });

  test('supports a selected weekly day and skips today after chatting', () {
    final monday = DateTime(2026, 9, 28, 8);
    expect(
      calculateCheckInDateTime(
        monday,
        const TimeOfDay(hour: 10, minute: 0),
        weekly: true,
        weekday: DateTime.monday,
        afterInteraction: true,
      ),
      DateTime(2026, 10, 5, 10),
    );
    expect(
      calculateCheckInDateTime(
        monday,
        const TimeOfDay(hour: 10, minute: 0),
        weekly: true,
        weekday: DateTime.tuesday,
        afterInteraction: false,
      ),
      DateTime(2026, 9, 29, 10),
    );
  });

  test('moves due-task notifications to the next quiet-hours boundary', () {
    expect(
      respectQuietHours(DateTime(2026, 9, 28, 8, 30)),
      DateTime(2026, 9, 28, 9),
    );
    expect(
      respectQuietHours(DateTime(2026, 9, 28, 22)),
      DateTime(2026, 9, 29, 9),
    );
    expect(
      respectQuietHours(DateTime(2026, 9, 28, 15)),
      DateTime(2026, 9, 28, 15),
    );
  });
}
