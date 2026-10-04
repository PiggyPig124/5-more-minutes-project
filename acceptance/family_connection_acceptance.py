"""Real localhost API + restart check, exclusively using synthetic state."""
import json, os, secrets, sys, tempfile
from pathlib import Path
import httpx
from process_restart_acceptance import _start_server, _stop_server, _free_port, _wait_for_health

def main():
    checks=[]
    def check(name, value):
        assert value, name
        checks.append(name)
    for key in ('MODEL_API_KEY','OPENAI_API_KEY','EMBEDDING_API_KEY','RESOURCE_EMBEDDING_API_KEY','TENCENT_ASR_SECRET_ID','TENCENT_ASR_SECRET_KEY'):
        os.environ.pop(key,None)
    os.environ['PYTHONDONTWRITEBYTECODE']='1'
    process=None
    try:
        with tempfile.TemporaryDirectory(prefix='family-acceptance-') as temp:
            path=Path(temp)/'synthetic.db'; secret=secrets.token_urlsafe(32); port=_free_port()
            base=f'http://127.0.0.1:{port}'
            process=_start_server(path,secret,port)
            check('isolated demo health',_wait_for_health(base,process))
            client=httpx.Client(base_url=base,timeout=15)
            def register(email, role):
                result=client.post('/auth/register',json=dict(email=email,password='synthetic-family-acceptance',display_name='Same Name',role=role))
                check('register '+role,result.status_code==201)
                auth=result.json();return auth,dict(Authorization='Bearer '+auth['access_token'])
            elder,eh=register('family-elder@example.invalid','elder')
            caregiver,ch=register('family-caregiver@example.invalid','caregiver')
            create=dict(elder_email=elder['account']['email'],client_request_id='first-request')
            request=client.post('/family-links/requests',headers=ch,json=create)
            check('pending request',request.status_code==201)
            check('pending no link',client.get('/family-links',headers=ch).json()==[])
            reject=dict(decision='reject',expected_version=request.json()['version'])
            check('explicit reject',client.post('/family-links/requests/'+request.json()['id']+'/decision',headers=eh,json=reject).json()['status']=='rejected')
            request=client.post('/family-links/requests',headers=ch,json={**create,'client_request_id':'second-request'}).json()
            approve=dict(decision='approve',expected_version=request['version'],scopes=['care_tasks','family_messages'])
            link=client.post('/family-links/requests/'+request['id']+'/decision',headers=eh,json=approve)
            check('explicit approval',link.status_code==200)
            link=link.json()
            message=dict(recipient_id=caregiver['account']['id'],content='Synthetic owner original',client_message_id='original',family_link_id=link['id'],expected_authorization_epoch=link['authorization_epoch'])
            old_unsent={**message,'client_message_id':'old-unsent','content':'Old unsent complete preview'}
            old_reply={**old_unsent,'recipient_id':elder['account']['id'],'client_message_id':'old-unsent-reply'}
            check('fresh share',client.post('/family-messages',headers=eh,json=message).status_code==201)
            block=dict(caregiver_id=caregiver['account']['id'],link_id=link['id'],client_operation_id='block')
            result=client.post('/family-links/blocks',headers=eh,json=block)
            check('block',result.status_code==200 and result.json()['active'])
            check('blocked incoming empty',client.get('/family-messages',headers=ch).json()==[])
            check('blocked request generic',client.post('/family-links/requests',headers=ch,json={**create,'client_request_id':'blocked'}).status_code==400)
            check('sender retained',client.get('/family-messages/sent',headers=eh).json()[0]['content']==message['content'])
            version=result.json()['version']
            clear=dict(expected_version=version,client_operation_id='unblock')
            check('unblock',client.post('/family-links/blocks/'+caregiver['account']['id']+'/unblock',headers=eh,json=clear).json()['active'] is False)
            check('unblock no permission',client.post('/family-messages',headers=eh,json=message).status_code==403)
            check('old approval terminal',client.post('/family-links/requests/'+request['id']+'/decision',headers=eh,json=approve).status_code==410)
            request=client.post('/family-links/requests',headers=ch,json={**create,'client_request_id':'fresh-after-unblock'}).json()
            new_approval=client.post('/family-links/requests/'+request['id']+'/decision',headers=eh,json={**approve,'expected_version':request['version']})
            check('new approval',new_approval.status_code==200)
            current=new_approval.json()
            check('old unsent elder preview denied',client.post('/family-messages',headers=eh,json=old_unsent).status_code==410)
            check('old unsent caregiver preview denied',client.post('/family-messages',headers=ch,json=old_reply).status_code==410)
            check('missing preview binding denied',client.post('/family-messages',headers=eh,json={k:v for k,v in old_unsent.items() if k not in ('family_link_id','expected_authorization_epoch')}).status_code==422)
            check('old key gone',client.post('/family-messages',headers=eh,json=message).status_code==410)
            check('old incoming still empty',client.get('/family-messages',headers=ch).json()==[])
            fresh_body={**message,'client_message_id':'fresh','content':'New authorized content','family_link_id':current['id'],'expected_authorization_epoch':current['authorization_epoch']}
            fresh_result=client.post('/family-messages',headers=eh,json=fresh_body)
            check('fresh new key share',fresh_result.status_code==201)
            retry=client.post('/family-messages',headers=eh,json=fresh_body)
            check('same preview same key retry is one message',retry.status_code==201 and retry.json()['id']==fresh_result.json()['id'])
            _stop_server(process);process=None
            process=_start_server(path,secret,port)
            check('restart health',_wait_for_health(base,process))
            client.close();client=httpx.Client(base_url=base,timeout=15)
            rows=client.get('/family-messages',headers=ch).json()
            check('restart preserves permanent withdrawal',len(rows)==1 and rows[0]['content']=='New authorized content')
            check('restart sender owns both records',len(client.get('/family-messages/sent',headers=eh).json())==2)
            client.close()
            _stop_server(process);process=None
    finally:
        if process: _stop_server(process)
    print(json.dumps({'passed':len(checks),'checks':checks,'database':'synthetic temporary SQLite','external_messages':False,'owned_servers_stopped':True},indent=2))
    return 0

if __name__=='__main__':sys.exit(main())
