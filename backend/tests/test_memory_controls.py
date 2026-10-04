from datetime import datetime, timezone
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from app.config import Settings
from app.main import create_app
from app.memory_models import PersonalMemory, MemoryConsent, MemoryEmbedding, Story, StoryMemoryLink
from app.memory_service import memory_revision
from app.models import Conversation, Message

@pytest.fixture
def setup(tmp_path):
    app=create_app(Settings(database_url=f'sqlite:///{tmp_path / "synthetic.db"}',auth_secret='memory-control-test',demo_mode=True))
    with TestClient(app,raise_server_exceptions=False) as client:
        accounts=[]
        for i,role in enumerate(['elder','elder','caregiver']):
            r=client.post('/auth/register',json={'email':f'control-{i}@example.test','password':'synthetic-password','display_name':f'Control {i}','role':role})
            assert r.status_code==201
            accounts.append(r.json())
        yield app,client,accounts

def auth(a): return {'Authorization':f'Bearer {a["access_token"]}'}
def state(c,a):
    r=c.get('/memories/control-state',headers=auth(a))
    assert r.status_code==200,r.text
    return r.json()
def headers(c,a): return {**auth(a),'X-Memory-Revision':str(state(c,a)['revision'])}
def enable(c,a,value=True):
    r=c.put('/memories/consent',headers=headers(c,a),json={'enabled':value})
    assert r.status_code==200,r.text
    return r.json()
def save(c,a,content='Owned test memory'):
    r=c.post('/memories/save',headers=headers(c,a),json={'content':content,'kind':'experience'})
    assert r.status_code==201,r.text
    return r.json()
def deletion(c,a,mode='all',ids=None,key='delete-request',revision=None):
    return c.post('/memories/deletions',headers=auth(a),json={'mode':mode,'memory_ids':ids or [],'expected_revision':state(c,a)['revision'] if revision is None else revision,'idempotency_key':key})

def test_state_and_off_preserve_management_and_delete_preserves_switch(setup):
    _,c,(a,_,_)=setup
    first=state(c,a);assert first['enabled'] is False and first['counts']['total']==0
    enable(c,a); m=save(c,a); enable(c,a,False)
    assert c.get('/memories',headers=auth(a)).json()[0]['id']==m['id']
    assert c.post('/memories/search',headers=auth(a),json={'query':'Owned'}).status_code==403
    r=deletion(c,a);assert r.status_code==200,r.text
    assert state(c,a)['enabled'] is False and state(c,a)['counts']['total']==0
    enable(c,a);save(c,a);assert deletion(c,a,key='second').status_code==200
    assert state(c,a)['enabled'] is True

def test_all_covers_hidden_states_and_preserves_other_owner_and_independent_data(setup):
    app,c,(a,b,_)=setup
    aid,bid=a['account']['id'],b['account']['id']
    with app.state.session_factory() as db:
        current=PersonalMemory(owner_id=aid,content='Current',status='confirmed');other=PersonalMemory(owner_id=bid,content='Other owner',status='confirmed')
        db.add_all([current,other]);db.flush()
        old=PersonalMemory(owner_id=aid,content='Old version',status='confirmed',superseded_by=current.id)
        hidden=PersonalMemory(owner_id=aid,content='Legacy deleted',deleted_at=datetime.now(timezone.utc))
        paused=PersonalMemory(owner_id=aid,content='Paused',status='confirmed',suppressed=True)
        candidate=PersonalMemory(owner_id=aid,content='Candidate')
        independent=Story(owner_id=aid,title='Independent',content='Keep this independent story')
        derived=Story(owner_id=aid,title='Derived',content='Remove linked story')
        db.add_all([old,hidden,paused,candidate,independent,derived]);db.flush()
        db.add(StoryMemoryLink(story_id=derived.id,memory_id=current.id));db.add(MemoryEmbedding(memory_id=current.id,embedding=[1.0]))
        db.commit();keep_id=independent.id;other_id=other.id
    assert state(c,a)['counts']['total']==5
    r=deletion(c,a);assert r.status_code==200,r.text
    assert r.json()['counts']['memories']==5 and r.json()['counts']['stories']==1
    with app.state.session_factory() as db:
        assert list(db.scalars(select(PersonalMemory).where(PersonalMemory.owner_id==aid)))==[]
        assert db.get(PersonalMemory,other_id).content=='Other owner'
        assert db.get(Story,keep_id).content=='Keep this independent story'
        assert list(db.scalars(select(MemoryEmbedding)))==[]

def test_selected_current_anchor_deletes_only_owner_reverse_chain(setup):
    app,c,(a,b,_)=setup
    enable(c,a);m=save(c,a);aid,bid=a['account']['id'],b['account']['id']
    with app.state.session_factory() as db:
        old=PersonalMemory(owner_id=aid,content='Own predecessor',superseded_by=m['id'])
        foreign=PersonalMemory(owner_id=bid,content='Foreign corrupt predecessor',superseded_by=m['id'])
        db.add_all([old,foreign]);db.commit();old_id=old.id;foreign_id=foreign.id
    assert deletion(c,a,'selected',[old_id],key='stale-anchor').status_code in [404,409]
    r=deletion(c,a,'selected',[m['id']]);assert r.status_code==200,r.text
    assert r.json()['counts']['memories']==2
    with app.state.session_factory() as db:
        assert db.get(PersonalMemory,old_id) is None
        assert db.get(PersonalMemory,foreign_id).content=='Foreign corrupt predecessor'

def test_same_key_retry_does_not_delete_new_save_and_conflicts_on_changed_request(setup):
    _,c,(a,_,_)=setup
    enable(c,a);m=save(c,a);rev=state(c,a)['revision']
    first=deletion(c,a,revision=rev);assert first.status_code==200,first.text
    new=save(c,a,'Saved after deletion')
    retry=deletion(c,a,revision=rev);assert retry.status_code==200 and retry.json()==first.json()
    assert c.get('/memories',headers=auth(a)).json()[0]['id']==new['id']
    assert deletion(c,a,'selected',[new['id']],revision=rev).status_code==409

def test_empty_delete_advances_version_and_stale_save_rejected(setup):
    _,c,(a,_,_)=setup
    enable(c,a);h=headers(c,a);rev=state(c,a)['revision']
    r=deletion(c,a,revision=rev);assert r.status_code==200 and r.json()['revision']>rev
    assert c.post('/memories/save',headers=h,json={'content':'Old RAM draft'}).status_code==409
    assert state(c,a)['counts']['total']==0

@pytest.mark.parametrize('method,path,payload',[('PUT','/memories/consent',{'enabled':True}),('POST','/memories',{'content':'Old candidate'}),('POST','/memories/save',{'content':'Old save'})])
def test_missing_revision_never_becomes_current(setup,method,path,payload):
    _,c,(a,_,_)=setup
    enable(c,a)
    assert c.request(method,path,headers=auth(a),json=payload).status_code==422

@pytest.mark.parametrize('role',['guest','caregiver','foreign'])
def test_delete_access_boundaries(setup,role):
    _,c,(a,b,care)=setup
    enable(c,a);m=save(c,a)
    h={} if role=='guest' else auth(care if role=='caregiver' else b)
    rev=0 if role!='foreign' else state(c,b)['revision']
    r=c.post('/memories/deletions',headers=h,json={'mode':'selected','memory_ids':[m['id']],'expected_revision':rev,'idempotency_key':'not-authorized'})
    assert r.status_code in [401,403,404]
    assert c.get('/memories',headers=auth(a)).json()[0]['id']==m['id']

def test_delete_rollback_has_no_receipt_or_partial_change(setup,monkeypatch):
    app,c,(a,_,_)=setup
    enable(c,a);m=save(c,a);rev=state(c,a)['revision']
    from app import memory_service
    original=memory_service.scrub_memory_references
    def fail(db,*args,**kwargs):
        original(db,*args,**kwargs)
        raise RuntimeError('Synthetic rollback test')
    monkeypatch.setattr(memory_service,'scrub_memory_references',fail)
    assert deletion(c,a,revision=rev).status_code==500
    assert state(c,a)['revision']==rev and state(c,a)['counts']['total']==1
    monkeypatch.setattr(memory_service,'scrub_memory_references',original)
    retry=deletion(c,a,revision=rev);assert retry.status_code==200,retry.text

def test_legacy_delete_requires_stable_key_and_replays_after_anchor_gone(setup):
    _,c,(a,_,_)=setup
    enable(c,a);m=save(c,a);h=headers(c,a)
    assert c.delete(f'/memories/{m["id"]}',headers=h).status_code==422
    h={**h,'Idempotency-Key':'legacy-delete'}
    assert c.delete(f'/memories/{m["id"]}',headers=h).status_code==204
    assert c.delete(f'/memories/{m["id"]}',headers=h).status_code==204
