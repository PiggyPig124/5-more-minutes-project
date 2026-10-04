"""Exact closed protocol labels, deliberately not a natural-language parser."""
TOPICS = {
 "gardening": frozenset(("gardening", "園藝")),
 "cooking": frozenset(("cooking", "烹飪")),
 "sewing": frozenset(("sewing", "tailoring and basic sewing", "裁縫")),
 "teaching": frozenset(("teaching", "教學")),
 "knitting": frozenset(("knitting", "編織")),
 "woodworking": frozenset(("woodworking", "木工")),
 "calligraphy": frozenset(("calligraphy", "書法")),
}

def protocol_topic(value: str) -> str | None:
 """Only a complete declared label is an identifier; never extract a phrase."""
 label = value.strip().casefold()
 return next((topic for topic, labels in TOPICS.items() if label in labels), None)

def eligible_skill_topic(skill, source) -> str | None:
 if source is None or source.kind not in {"experience", "fact"}:
  return None
 if skill.status != "confirmed" or skill.owner_id != source.owner_id:
  return None
 topic = protocol_topic(skill.suggestion)
 return topic if topic and topic == protocol_topic(source.content) else None
