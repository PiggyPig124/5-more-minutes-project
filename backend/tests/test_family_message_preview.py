"""Preview binding: late first deliveries cannot acquire a newer consent epoch."""
import pytest
from tests.test_family_requests import requests, create_request, decision
from tests.test_family_blocks import block, unblock
from tests.test_family_messages import link_accounts
from tests.test_integration import _headers

def preview(link,recipient,key,content='Captured original preview',**extra):
    return dict(recipient_id=recipient['account']['id'],content=content,
        client_message_id=key,family_link_id=link['id'],
        expected_authorization_epoch=link['authorization_epoch'],**extra)

def reconnect(c,elder,child,link):
    assert block(c,elder,child,link_id=link['id']).status_code==200
    assert unblock(c,elder,child).status_code==200
    row=create_request(c,child,elder,key='new-preview-request')
    result=decision(c,elder,row['id'],scopes=['family_messages'])
    assert result.status_code==200,result.text
    assert result.json()['authorization_epoch']>link['authorization_epoch']
    return result.json()

@pytest.mark.parametrize('direction',['elder','caregiver'])
def test_unsent_old_preview_cannot_be_promoted_after_reconnection(requests,direction):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages'])
    sender,recipient=(elder,child) if direction=='elder' else (child,elder)
    captured=preview(link,recipient,'unsent-old')
    current=reconnect(c,elder,child,link)
    old=c.post('/family-messages',headers=_headers(sender),json=captured)
    assert old.status_code==410,old.text
    assert c.get('/family-messages',headers=_headers(recipient)).json()==[]
    # The old failed body is not upgraded or retried with a fresh epoch.
    assert c.post('/family-messages',headers=_headers(sender),json=captured).status_code==410
    fresh=preview(current,recipient,'fresh-preview','Explicit new preview')
    result=c.post('/family-messages',headers=_headers(sender),json=fresh)
    assert result.status_code==201,result.text
    replay=c.post('/family-messages',headers=_headers(sender),json=fresh)
    assert replay.status_code==201 and replay.json()['id']==result.json()['id']
    assert [x['content'] for x in c.get('/family-messages',headers=_headers(recipient)).json()]==['Explicit new preview']

@pytest.mark.parametrize('change',[
    {'family_link_id':None},{'expected_authorization_epoch':None},
    {'expected_authorization_epoch':0},{'expected_authorization_epoch':True},
    {'expected_authorization_epoch':'1'},
])
def test_missing_or_invalid_preview_binding_is_rejected_before_write(requests,change):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages'])
    payload=preview(link,child,'missing-binding')
    for key,value in change.items():
        if value is None:payload.pop(key)
        else:payload[key]=value
    assert c.post('/family-messages',headers=_headers(elder),json=payload).status_code==422
    assert c.get('/family-messages',headers=_headers(child)).json()==[]

def test_wrong_preview_link_is_rejected_and_cannot_replay_existing_key(requests):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages']);payload=preview(link,child,'current')
    first=c.post('/family-messages',headers=_headers(elder),json=payload)
    assert first.status_code==201,first.text
    mismatch=c.post('/family-messages',headers=_headers(elder),json={**payload,'family_link_id':'different-link'})
    assert mismatch.status_code==410,mismatch.text
    assert len(c.get('/family-messages',headers=_headers(child)).json())==1

def test_unsent_story_preview_keeps_both_family_epoch_and_memory_revision(requests):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages'])
    rev=c.get('/memories/control-state',headers=_headers(elder)).json()['revision']
    h={**_headers(elder),'X-Memory-Revision':str(rev)}
    enabled=c.put('/memories/consent',headers=h,json={'enabled':True});assert enabled.status_code==200,enabled.text
    rev=enabled.json()['revision'];h['X-Memory-Revision']=str(rev)
    result=c.post('/stories',headers=h,json={'title':'Title','content':'Source body','memory_ids':[]})
    assert result.status_code==201,result.text
    story=result.json();h['X-Memory-Revision']=str(story['revision'])
    old=preview(link,child,'old-unsent-card',story['title']+'\n'+story['content'],source_story_id=story['id'])
    current=reconnect(c,elder,child,link)
    assert c.post('/family-messages',headers=h,json=old).status_code==410
    assert c.get('/family-messages',headers=_headers(child)).json()==[]
    fresh=preview(current,child,'new-card-preview',old['content'],source_story_id=story['id'])
    sent=c.post('/family-messages',headers=h,json=fresh);assert sent.status_code==201,sent.text
    assert c.post('/family-messages',headers=h,json=fresh).json()['id']==sent.json()['id']
    stale_header={**h,'X-Memory-Revision':str(story['revision']-1)}
    assert c.post('/family-messages',headers=stale_header,json=fresh).status_code==409


def test_unsent_support_preview_cannot_use_new_family_authorization(requests):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages'])
    contact=c.post('/safety/emergency-contacts',headers=_headers(elder),json={'family_link_id':link['id'],'label':'Contact'})
    assert contact.status_code==201,contact.text
    old=dict(emergency_contact_id=contact.json()['id'],message='Old support preview',idempotency_key='unsent-support',family_link_id=link['id'],expected_authorization_epoch=link['authorization_epoch'])
    current=reconnect(c,elder,child,link)
    rejected=c.post('/safety/support-request',headers=_headers(elder),json=old)
    assert rejected.status_code==410,rejected.text
    assert c.get('/family-messages',headers=_headers(child)).json()==[]
    fresh={**old,'idempotency_key':'fresh-support-preview','family_link_id':current['id'],'expected_authorization_epoch':current['authorization_epoch']}
    first=c.post('/safety/support-request',headers=_headers(elder),json=fresh);assert first.status_code==200,first.text
    retry=c.post('/safety/support-request',headers=_headers(elder),json=fresh)
    assert retry.status_code==200 and retry.json()['family_message_id']==first.json()['family_message_id']
    assert len(c.get('/family-messages',headers=_headers(child)).json())==1

def test_support_missing_preview_binding_never_writes(requests):
    app,c,elder,child,_,_=requests
    link=link_accounts(c,elder,child,['family_messages'])
    contact=c.post('/safety/emergency-contacts',headers=_headers(elder),json={'family_link_id':link['id'],'label':'Contact'}).json()
    body=dict(emergency_contact_id=contact['id'],message='Unbound preview',idempotency_key='missing-support')
    assert c.post('/safety/support-request',headers=_headers(elder),json=body).status_code==422
    assert c.get('/family-messages',headers=_headers(child)).json()==[]
