"""F01/F03 acceptance against real API, seeded public records, synthetic users."""
import hashlib
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func,select
from app.config import Settings
from app.main import create_app
from app.models import Account,Conversation,Message,ActionProposal
from app.memory_models import PersonalMemory

MTR='https://www.mtr.com.hk/ch/customer/main/jp.html'
HA='https://www.ha.org.hk/visitors/ha_visitor_guide.asp'

@pytest.fixture
def api(tmp_path):
    app=create_app(Settings(database_url='sqlite:///'+(tmp_path/'guidance.db').as_posix(),auth_secret='synthetic-guidance',demo_mode=True))
    with TestClient(app) as client: yield app,client

def turn(client,role,text):
    if role=='guest':
        session=client.post('/guest/sessions').json()
        response=client.post('/guest/sessions/'+session['session_id']+'/messages',json={'content':text})
        assert response.status_code==200,response.text
        return response.json(),None
    auth=client.post('/auth/register',json={'email':'guide@example.invalid','password':'synthetic-guidance-2026','display_name':'Guide','role':'elder'}).json()
    headers={'Authorization':'Bearer '+auth['access_token']}
    conversation=client.post('/conversations',headers=headers,json={}).json()
    response=client.post('/conversations/'+conversation['id']+'/messages',headers=headers,json={'content':text,'client_message_id':'guide'})
    assert response.status_code==200,response.text
    message=response.json()['assistant_message']
    return {'reply':message['content'],'mode':message['metadata_json']['mode'],'message':message,'headers':headers},None

@pytest.mark.parametrize('role',['guest','elder'])
@pytest.mark.parametrize('question,official_url',[
    ('我想去旺角，點搭港鐵？車費幾多？',MTR),
    ('How do I get from Central to Mong Kok by MTR and what is the fare?',MTR),
    ('點樣預約普通科門診？要等幾耐？',HA),
    ('How can I book a clinic appointment and check the waiting time?',HA),
    ('Can you read my medical records and book my appointment?',HA),
])
def test_chat_routes_to_official_navigation_without_calculating_or_acting(api,role,question,official_url):
    app,client=api
    result,_=turn(client,role,question)
    assert official_url in result['reply'],result['reply']
    assert '2026-09-20' in result['reply']
    assert result['mode']=='official_guidance'
    assert '$2' not in result['reply'] and '半價' not in result['reply']
    assert ('不會' in result['reply'] or 'cannot' in result['reply'].lower())
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count(ActionProposal.id)))==0
        assert db.scalar(select(func.count(PersonalMemory.id)))==0
        if role=='guest':
            for model in (Account,Conversation,Message):assert db.scalar(select(func.count(model.id)))==0
    if role=='elder':
        prepared=client.post('/answer-cards/prepare',headers=result['headers'],json={'source_message_id':result['message']['id']})
        assert prepared.status_code==200,prepared.text
        assert any(s['url'].startswith(official_url) for s in prepared.json()['public_sources'])

def test_navigation_never_calls_configured_model_or_proposes_booking(api):
    app,client=api
    class ForbiddenProvider:
        mode='openai_compatible'
        async def reply(self,*args):raise AssertionError('Official navigation must not reach a model or leak the private query')
    app.state.orchestrator.adapter=ForbiddenProvider()
    result,_=turn(client,'guest','Please book a clinic appointment for my private medical condition.')
    assert result['mode']=='official_guidance'
    assert HA in result['reply']

def test_guest_answer_has_manifest_bound_public_sources_without_private_fields(api):
    app,client=api
    result,_=turn(client,'guest','How can I get a medical fee waiver?')
    assert result.get('answer_card_sources_version')==1
    sources=result.get('answer_card_sources',[])
    assert sources,'A sourced current guest answer must keep structured sources'
    expected={'source_id','organisation','title','url','reviewed_at','retrieved_at','effective_date','verification_scope','content_hash'}
    for source in sources:
        assert set(source)==expected
        assert source['reviewed_at']=='2026-09-20'
        assert len(source['content_hash'])==64
        assert 'AI answer' in source['verification_scope']
    assert not any('owner' in k or 'memory' in k for s in sources for k in s)

def test_navigation_does_not_use_wrong_domain_rehabus_record(api):
    _,client=api
    result,_=turn(client,'guest','點查復康巴士路線同車費？')
    assert 'hkab.org.hk' not in result['reply']
    assert all(s['source_id']!='transport-rehabus-2026' for s in result.get('answer_card_sources',[]))

def test_missing_navigation_records_degrades_without_invented_sources(api,monkeypatch):
    from app.resource_service import get_default_resource_service
    _,client=api
    service=get_default_resource_service()
    monkeypatch.setattr(service,'records',tuple(r for r in service.records if r.category!='healthcare_navigation'))
    result,_=turn(client,'guest','How can I book a clinic appointment?')
    assert result['mode']=='official_guidance'
    assert result.get('answer_card_sources',[])==[]
    assert 'https://' not in result['reply']
    assert '核實' in result['reply'] or 'verified' in result['reply'].lower()

def test_urgent_safety_precedes_medical_navigation(api):
    _,client=api
    result,_=turn(client,'guest','I want to kill myself. How can I book a clinic appointment?')
    assert result['mode']=='safety_intervention'
    assert result.get('answer_card_sources',[])==[]

def test_retry_preserves_official_guidance_mode_and_does_not_add_a_turn(api):
    app,client=api
    question='How do I travel by MTR?'
    first,_=turn(client,'elder',question)
    response=client.post('/conversations/'+first['message']['conversation_id']+'/messages',
        headers=first['headers'],json={'content':question,'client_message_id':'guide'})
    assert response.status_code==200,response.text
    assert response.json()['mode']=='official_guidance'
    assert response.json()['assistant_message']['id']==first['message']['id']
    with app.state.session_factory() as db:
        assert db.scalar(select(func.count(Message.id)))==2

def test_official_navigation_does_not_send_opted_in_memory_or_query_to_embedding(api,monkeypatch):
    from app.routers import conversations
    _,client=api
    auth=client.post('/auth/register',json={'email':'private-navigation@example.invalid','password':'synthetic-private-2026','display_name':'Private','role':'elder'}).json()
    headers={'Authorization':'Bearer '+auth['access_token']}
    initial=client.get('/memories/control-state',headers=headers).json()
    enabled=client.put('/memories/consent',headers={**headers,'X-Memory-Revision':str(initial['revision'])},json={'enabled':True})
    assert enabled.status_code==200
    async def forbidden_retrieval(*args):raise AssertionError('Fixed official navigation must bypass private-memory/embedding retrieval')
    monkeypatch.setattr(conversations,'retrieve_for_chat',forbidden_retrieval)
    conversation=client.post('/conversations',headers=headers,json={}).json()
    response=client.post('/conversations/'+conversation['id']+'/messages',headers=headers,json={'content':'How can I book a clinic appointment for my private condition?','client_message_id':'private-guide'})
    assert response.status_code==200,response.text
    assert response.json()['mode']=='official_guidance'
    metadata=response.json()['assistant_message']['metadata_json']
    assert metadata['memory_sources']==[] and metadata['memory_retrieval_mode']=='disabled'

@pytest.mark.parametrize('question,url',[
    ('Calculate the MTR fare from Central to Mong Kok',MTR),
    ('Tell me the hospital waiting time',HA),
    ('I need a clinic appointment',HA),
    ('Please read my medical records and remind me tomorrow',HA),
    ('Please book a clinic appointment and ask about fee waiver',HA),
    ('I cannot remember how to book a clinic appointment',HA),
    ('Please book my clinic appointment; remember I need wheelchair access',HA),
    ('Calculate the MTR fare and remind me to top up tomorrow',MTR),
    ('Tell me the hospital waiting time and remind me to leave tomorrow',HA),
    ('Calculate my bus fare and explain the welfare subsidy','https://www.td.gov.hk/tc/transport_in_hong_kong/public_transport/bus/'),
    ('MTR fare?',MTR),
    ('Hospital waiting time?',HA),
])
def test_imperative_or_mixed_navigation_request_cannot_bypass_fixed_handoff(api,question,url):
    _,client=api
    result,_=turn(client,'guest',question)
    assert result['mode']=='official_guidance'
    assert url in result['reply']

@pytest.mark.parametrize('question',[
    'Please remember that I prefer taking the MTR',
    'Do you remember what route I took?',
    'Can you help me book a hair appointment?',
    'Remind me to book my clinic appointment tomorrow',
])
def test_memory_recall_and_unrelated_appointments_keep_their_existing_flows(api,question):
    _,client=api
    result,_=turn(client,'guest',question)
    assert result['mode']!='official_guidance'
    assert MTR not in result['reply'] and HA not in result['reply']
