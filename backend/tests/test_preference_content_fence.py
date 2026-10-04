"""Content withdrawal fences preserve punctuation; synthetic real-route regressions."""
import pytest
from fastapi.testclient import TestClient
from app.main import create_app
from tests.test_agent_memory_community import _settings, _enable_memory, _conversation, _send, _memory_action, MockMemoryModel
from tests.test_integration import _register
from tests.memory_revision_helpers import memory_revision_headers

@pytest.mark.parametrize('operation',['pause','delete'])
@pytest.mark.parametrize('first,second,key1,key2',[
 ('I enjoy gardening.','I enjoy cooking.','gardening','cooking'),
 ('I enjoy C++ programming.','I enjoy C programming.','cplusplus_programming','c_programming'),
])
def test_withdrawal_does_not_block_independent_preference(tmp_path,operation,first,second,key1,key2):
 app=create_app(_settings(tmp_path/'synthetic.db'))
 with TestClient(app) as c:
  owner=_register(c,'independent@example.test');h=_enable_memory(c,owner);conv=_conversation(c,h)
  app.state.orchestrator=MockMemoryModel([[_memory_action('save_preference',first,content=first,topic_key=key1)],[_memory_action('save_preference',second,content=second,topic_key=key2)]])
  r=_send(c,h,conv,first,'first');assert r.status_code==200
  mid=r.json()['assistant_message']['metadata_json']['auto_saved_memory']['id']
  if operation=='pause':
   r=c.patch('/memories/'+mid,headers=memory_revision_headers(c,h),json={'suppressed':True})
  else:
   r=c.delete('/memories/'+mid,headers={**memory_revision_headers(c,h),'Idempotency-Key':'synthetic-withdraw'})
  assert r.status_code in (200,204)
  r=_send(c,h,conv,second,'second');assert r.status_code==200
  metadata=r.json()['assistant_message']['metadata_json']
  assert 'auto_saved_memory' in metadata, f'Unrelated preference blocked: {first!r} -> {second!r}; {metadata}'
  assert metadata['auto_saved_memory']['content']==second

@pytest.mark.parametrize('operation',['pause','delete'])
def test_unrelated_manual_save_does_not_clear_withdrawn_content_fence(tmp_path,operation):
 first='I enjoy C++ programming.';second='I enjoy C programming.'
 app=create_app(_settings(tmp_path/'synthetic-manual.db'))
 with TestClient(app) as c:
  owner=_register(c,'manual-independent@example.test');h=_enable_memory(c,owner);conv=_conversation(c,h)
  app.state.orchestrator=MockMemoryModel([[_memory_action('save_preference',first,content=first,topic_key='cplusplus_programming')],[_memory_action('save_preference',first,content=first,topic_key='renamed_cpp')]])
  r=_send(c,h,conv,first,'first');assert r.status_code==200
  mid=r.json()['assistant_message']['metadata_json']['auto_saved_memory']['id']
  if operation=='pause':
   r=c.patch('/memories/'+mid,headers=memory_revision_headers(c,h),json={'suppressed':True})
  else:
   r=c.delete('/memories/'+mid,headers={**memory_revision_headers(c,h),'Idempotency-Key':'synthetic-withdraw'})
  assert r.status_code in (200,204)
  saved=c.post('/memories/save',headers=memory_revision_headers(c,h),json={'content':second,'kind':'preference','topic_key':'c_programming'})
  assert saved.status_code==201,saved.text
  r=_send(c,h,conv,first,'later');assert r.status_code==200
  assert 'auto_saved_memory' not in r.json()['assistant_message']['metadata_json'], 'Unrelated manual Save cleared the withdrawn C++ content fence and allowed renamed-topic recapture'


def old_body_hash(owner_id, content):
    # The previous shipped implementation, intentionally retained in the test
    # rather than using a production compatibility helper to generate itself.
    import hashlib
    import re
    normalized = re.sub(r"[^\w\u3400-\u9fff]+", "", content.casefold())
    return hashlib.sha256(f"{owner_id}\0content\0{normalized}".encode()).hexdigest()


@pytest.mark.parametrize("manual_content", ["I enjoy C programming.", "I enjoy C++ programming."])
def test_legacy_ambiguous_body_fence_is_retained_on_explicit_save(tmp_path, manual_content):
    from app.memory_models import MemoryPreferenceBlock
    from sqlalchemy import select
    app = create_app(_settings(tmp_path / "old-fence.db"))
    with TestClient(app) as c:
        owner = _register(c, "legacy@example.test")
        h = _enable_memory(c, owner)
        oid = owner["account"]["id"]
        old_hash = old_body_hash(oid, "I enjoy C++ programming.")
        with app.state.session_factory() as db:
            db.add(MemoryPreferenceBlock(owner_id=oid, topic_hash=old_hash, reason="deleted"))
            db.commit()
        saved = c.post("/memories/save", headers=memory_revision_headers(c, h),
            json={"content": manual_content, "kind": "preference", "topic_key": "manual"})
        assert saved.status_code == 201, saved.text
        with app.state.session_factory() as db:
            assert db.get(MemoryPreferenceBlock, (oid, old_hash)) is not None
        app.state.orchestrator = MockMemoryModel([[_memory_action("save_preference",
            "I enjoy C++ programming.", content="I enjoy C++ programming.", topic_key="new_cpp")]])
        result = _send(c, h, _conversation(c, h), "I enjoy C++ programming.", "later")
        assert result.status_code == 200, result.text
        assert "auto_saved_memory" not in result.json()["assistant_message"]["metadata_json"]


def test_legacy_fence_does_not_become_inert_after_hash_upgrade(tmp_path):
    from app.memory_models import MemoryPreferenceBlock
    app = create_app(_settings(tmp_path / "legacy-guard.db"))
    with TestClient(app) as c:
        owner = _register(c, "legacy-guard@example.test")
        h = _enable_memory(c, owner)
        with app.state.session_factory() as db:
            db.add(MemoryPreferenceBlock(owner_id=owner["account"]["id"],
                topic_hash=old_body_hash(owner["account"]["id"], "I enjoy gardening."), reason="deleted"))
            db.commit()
        app.state.orchestrator = MockMemoryModel([[_memory_action("save_preference",
            "I enjoy gardening.", content="I enjoy gardening.", topic_key="renamed_gardening")]])
        result = _send(c, h, _conversation(c, h), "I enjoy gardening.", "later")
        assert result.status_code == 200, result.text
        assert "auto_saved_memory" not in result.json()["assistant_message"]["metadata_json"]


def test_v2_and_legacy_content_fences_use_distinct_namespaces():
    from app.memory_service import _preference_content_hash
    assert _preference_content_hash("owner", "gardening") != old_body_hash("owner", "gardening")
    assert _preference_content_hash("owner", "I enjoy C++ programming.") != _preference_content_hash("owner", "I enjoy C programming.")


@pytest.mark.parametrize("restored_content", ["I enjoy C programming.", "I enjoy C++ programming."])
def test_restore_does_not_erase_ambiguous_legacy_content_barrier(tmp_path, restored_content):
    from app.memory_models import MemoryPreferenceBlock, PersonalMemory
    app = create_app(_settings(tmp_path / "legacy-restore.db"))
    with TestClient(app) as c:
        owner = _register(c, "legacy-restore@example.test")
        h = _enable_memory(c, owner)
        oid = owner["account"]["id"]
        old_hash = old_body_hash(oid, "I enjoy C++ programming.")
        with app.state.session_factory() as db:
            memory = PersonalMemory(owner_id=oid, content=restored_content, kind="preference",
                status="confirmed", suppressed=True, topic_key="restored")
            db.add(memory)
            db.add(MemoryPreferenceBlock(owner_id=oid, topic_hash=old_hash, reason="paused"))
            db.commit()
            memory_id = memory.id
        restored = c.patch("/memories/" + memory_id, headers=memory_revision_headers(c, h),
            json={"suppressed": False})
        assert restored.status_code == 200 and restored.json()["suppressed"] is False
        with app.state.session_factory() as db:
            assert db.get(MemoryPreferenceBlock, (oid, old_hash)) is not None
        app.state.orchestrator = MockMemoryModel([[_memory_action("save_preference",
            "I enjoy C++ programming.", content="I enjoy C++ programming.", topic_key="new_cpp")]])
        result = _send(c, h, _conversation(c, h), "I enjoy C++ programming.", "later")
        assert result.status_code == 200, result.text
        assert "auto_saved_memory" not in result.json()["assistant_message"]["metadata_json"]


@pytest.mark.parametrize("first,second", [
    ("I enjoy C++ programming.", "I enjoy C programming."),
    ("I enjoy C# programming.", "I enjoy C programming."),
    ("I enjoy A/B testing.", "I enjoy AB testing."),
])
def test_content_fence_keeps_distinguishing_punctuation(first, second):
    from app.memory_service import _preference_content_hash
    assert _preference_content_hash("owner", first) != _preference_content_hash("owner", second)


def test_body_normalization_retains_word_boundaries():
    from app.memory_service import _preference_content_hash
    assert _preference_content_hash("owner", "I enjoy AB testing.") != _preference_content_hash("owner", "I enjoy A B testing.")
    assert _preference_content_hash("owner", "  I enjoy C++ programming. ") == _preference_content_hash("owner", "I   enjoy C++ programming.")
