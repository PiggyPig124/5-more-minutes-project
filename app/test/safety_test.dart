import 'package:anxin_companion/src/safety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects direct English and Chinese urgent-risk statements', () {
    expect(detectsUrgentRisk('I want to kill myself'), isTrue);
    expect(detectsUrgentRisk('I might hurt myself tonight'), isTrue);
    expect(detectsUrgentRisk("I don't want to live"), isTrue);
    expect(detectsUrgentRisk('我想死'), isTrue);
    expect(detectsUrgentRisk('我不想活了'), isTrue);
    expect(detectsUrgentRisk('我想傷害自己'), isTrue);
  });

  test('does not trigger for explicit negation or unrelated distress', () {
    expect(detectsUrgentRisk("I am not suicidal"), isFalse);
    expect(detectsUrgentRisk("I don't want to hurt myself"), isFalse);
    expect(detectsUrgentRisk('我不想自殺'), isFalse);
    expect(detectsUrgentRisk('我沒有想自殺'), isFalse);
    expect(detectsUrgentRisk('I feel lonely today'), isFalse);
  });
}
