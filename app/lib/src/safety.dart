final _negatedRisk = RegExp(
  r"\b(?:not|never|don't|do not|didn't|did not)\b.{0,36}?\b(?:suicidal|want to die|kill myself|hurt myself|end my life)\b",
  caseSensitive: false,
);

final _directRisk = RegExp(
  r"\b(?:i(?:'m| am)?\s+(?:suicidal|going to kill myself|going to hurt myself|thinking about hurting myself)|i\s+(?:want to die|don't want to live|do not want to live|want to kill myself|think about suicide|have been thinking about suicide|plan to (?:die|kill myself|hurt myself)|might hurt myself|will hurt myself|want to end my life))\b",
  caseSensitive: false,
);

final _chineseNegatedRisk = RegExp(
  r"(?:(?:沒有|没|唔會|唔会|不會|不会|不曾|冇諗過|沒有想過).{0,8}?(?:想死|想自殺|想自杀|自殺|自杀|傷害自己|伤害自己)|(?:不想|唔想)(?:自殺|自杀|傷害自己|伤害自己))",
);

final _chineseDirectRisk = RegExp(
  r"(?:我.{0,5}(?:想死|不想活|唔想活|想自殺|想自杀|要自殺|要自杀|想傷害自己|想伤害自己|有自殺念頭|有自杀念头)|(?:不想活|唔想活|想自殺|想自杀|要自殺|要自杀))",
);

bool detectsUrgentRisk(String message) {
  final clauses = message.replaceAll('’', "'").split(RegExp(
        r'[\n.!?;,。！？；，]|\b(?:but|however|yet|and)\b|但是|但|不過|不过|可是|然而|而且',
        caseSensitive: false,
      ));
  for (final clause in clauses) {
    final negations = [
      ..._negatedRisk.allMatches(clause),
      ..._chineseNegatedRisk.allMatches(clause),
    ];
    for (final pattern in [_directRisk, _chineseDirectRisk]) {
      for (final match in pattern.allMatches(clause)) {
        if (!negations.any((negation) =>
            negation.start < match.end && negation.end > match.start)) {
          return true;
        }
      }
    }
  }
  return false;
}
