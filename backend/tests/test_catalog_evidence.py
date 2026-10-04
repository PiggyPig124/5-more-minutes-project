"""Closed protocol evidence; no natural language polarity classifier."""
import pytest
from app.community_models import CommunitySkill
from app.memory_models import PersonalMemory
from .test_catalog_validity import catalog, activity, add_memory, consent
from .test_safety_checkin_speech import _headers

PROSE = ["不喜欢唱歌", "唔鍾意唱歌", "我唔識園藝", "I dislike gardening",
 "I don't enjoy gardening", "I no longer enjoy gardening", "I don't dislike gardening",
 "不是不喜欢园艺", "喜欢园艺，但不喜欢园艺比赛", "I like gardening, not gardening contests",
 "女兒鍾意園藝", "She said 'I love gardening'", "Gardening is a book title",
 "I teach the gardening teacher computers", "可能試下園藝", "暫時唔参加園藝",
 "I enjoy gardening", "Gardening maybe", "Gardening, but no volunteering"]

def skill(app, owner, mid, label='Gardening', status='confirmed'):
 with app.state.session_factory() as db:
  row=CommunitySkill(owner_id=owner['account']['id'],memory_id=mid,suggestion=label,status=status)
  db.add(row);db.commit();return row.id

def result(client, elder):
 return client.get('/community/catalog/recommendations',headers=_headers(elder)).json()

def general(body):
 assert body['basis']=='general' and body['memory_matches']==0
 assert body['recommendations'] and all(x['recommendation_basis']=='general' and not x['recommendation_reasons'] for x in body['recommendations'])

@pytest.mark.parametrize('text',PROSE)
def test_free_preference_and_unresolved_conflict_are_general(catalog,text):
 app,client,elder,_=catalog;consent(app,elder);activity(app,interest_tags=['唱歌','gardening','園藝'],skill_tags=['gardening'])
 mid=add_memory(app,elder,'Gardening',kind='experience');skill(app,elder,mid)
 add_memory(app,elder,text);general(result(client,elder))

@pytest.mark.parametrize('text',PROSE)
def test_free_skill_edit_or_source_never_matches_substrings(catalog,text):
 app,client,elder,_=catalog;consent(app,elder);activity(app,skill_tags=['gardening','園藝','唱歌'])
 mid=add_memory(app,elder,text,kind='experience');skill(app,elder,mid,label=text)
 general(result(client,elder))

def test_closed_confirmed_skill_has_exact_explainable_match(catalog):
 app,client,elder,_=catalog;consent(app,elder)
 activity(app,'exact',skill_tags=['gardening']);activity(app,'substring',skill_tags=['garden'])
 mid=add_memory(app,elder,'Gardening',kind='experience');skill(app,elder,mid)
 body=result(client,elder);assert body['basis']=='memory' and body['memory_matches']==1
 assert [a['id'] for a in body['recommendations']]==['exact']
 assert body['recommendations'][0]['recommendation_reasons']==[{'memory_id':mid,'source_type':'skill','source_text':'Gardening','matched_tag':'gardening'}]

@pytest.mark.parametrize('state',['candidate','suppressed','superseded','skill_rejected','skill_suggested','mismatched_source','unknown'])
def test_ineligible_or_old_evidence_is_general(catalog,state):
 app,client,elder,_=catalog;consent(app,elder);activity(app,skill_tags=['gardening'])
 values={};status='confirmed';content='Gardening'
 if state=='candidate':values['status']='candidate'
 if state=='suppressed':values['suppressed']=True
 if state=='superseded':values['superseded_by']=add_memory(app,elder,'I dislike gardening',status='candidate')
 if state.startswith('skill_'):status=state[6:]
 if state=='mismatched_source':content='Cooking'
 if state=='unknown':content='Uncatalogued gardening skill'
 mid=add_memory(app,elder,content,kind='experience',**values);skill(app,elder,mid,status=status)
 general(result(client,elder))

def test_edit_then_reconfirm_does_not_reuse_old_skill(catalog):
 app,client,elder,_=catalog;consent(app,elder);activity(app,skill_tags=['gardening'])
 mid=add_memory(app,elder,'Gardening',kind='experience');skill(app,elder,mid)
 assert result(client,elder)['basis']=='memory'
 headers=_headers(elder);revision=client.get('/memories/control-state',headers=headers).json()['revision']
 response=client.patch('/memories/'+mid,headers={**headers,'X-Memory-Revision':str(revision)},json={'content':'I dislike gardening'})
 assert response.status_code==200;general(result(client,elder))
 new=response.json()['id'];revision=client.get('/memories/control-state',headers=headers).json()['revision']
 assert client.post('/memories/'+new+'/confirm',headers={**headers,'X-Memory-Revision':str(revision)}).status_code==200
 general(result(client,elder))


def test_unparsed_confirmed_skill_conflict_blocks_personal_evidence(catalog):
 app,client,elder,_=catalog;consent(app,elder);activity(app,skill_tags=['gardening'])
 positive=add_memory(app,elder,'Gardening',kind='fact');skill(app,elder,positive)
 other=add_memory(app,elder,'I cannot do gardening',kind='experience')
 skill(app,elder,other,label='I cannot do gardening')
 general(result(client,elder))

def test_chinese_protocol_label_matches_only_confirmed_skill(catalog):
 app,client,elder,_=catalog;consent(app,elder);activity(app,skill_tags=['gardening'])
 mid=add_memory(app,elder,'園藝',kind='experience');skill(app,elder,mid,label='園藝')
 body=result(client,elder);assert body['basis']=='memory' and body['memory_matches']==1
 assert body['recommendations'][0]['recommendation_reasons'][0]['source_text']=='園藝'
