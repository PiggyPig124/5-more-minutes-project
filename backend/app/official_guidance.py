"""Conservative public navigation. No query, identity or memory leaves this service.

Use existing manifest identities and dates, but never repeat legacy fare/queue
claims as current facts. This is a signpost, not routing, records or booking.
"""
from __future__ import annotations
import re
from .resource_service import get_default_resource_service, _record_hash
from .answer_card_service import sanitized_sources

_WELFARE=re.compile(r'福利|津貼|津贴|補助|补助|資助|资助|醫療費|医疗费|覆診費|覆诊费|照顧者支援|照顾者支援|社區照顧|社区照顾|長者中心|长者中心|\bwelfare\b|\bsubsid(?:y|ies)\b|\bfee waiver\b|\bcaregiver support\b',re.I)
_REQUEST=re.compile(r'[?？]|\b(?:how|where|what|which|can|could|show|help|book|booking|check|tell|calculate|compute|find)\b|點|怎|如何|幾|多少|想查|想睇|想看|要查|查詢|查询|預約|预约',re.I)
_TRANSPORT=re.compile(r'港鐵|港铁|地鐵|地铁|巴士|搭車|搭车|路線|路线|車費|车费|交通|旅程|點(?:樣)?去|怎(?:樣|么)去|如何去|\b(?:mtr|bus|transport|fare|route|journey planner)\b|\bhow (?:do|can|to).{0,30}\bget (?:from|to)\b',re.I)
_HEALTHCARE=re.compile(r'門診|门诊|覆診|覆诊|醫院|医院|診所|诊所|病歷|病历|醫療紀錄|医疗记录|\b(?:clinic|hospital|doctor|medical records?|health records?|medical appointment|ha go|gopc)\b',re.I)
_REMINDER=re.compile(r'\bremind(?:er)?\b|提醒|提我|記得叫我|记得叫我',re.I)
_MEMORY_REQUEST=re.compile(r'^\s*(?:(?:please\s+)?(?:remember|recall|forget|save)\b|(?:do|can|could)\s+you\s+(?:remember|recall)\b|(?:請|请)?(?:記住|记住|記低|記得|记得|忘記|忘记)|之前.{0,10}(?:講|說|说|提))',re.I)
_CLAUSE_BREAK=re.compile(r'(?<=[?？])|[\n.!;,。！；，]|\b(?:and|but|however)\b|同埋|而且|但是|但係|但系',re.I)
_HEALTH_ACTION=re.compile(
    r'\b(?:read|access|show|check)\b.{0,40}\b(?:medical|health) records?\b|'
    r'\b(?:book|arrange|schedule|need|want)\b.{0,40}\b(?:clinic|hospital|doctor|medical appointment)\b|'
    r'(?:睇|查|讀取|读取|查看|查閱|查阅).{0,12}(?:病歷|病历|醫療紀錄|医疗记录)|'
    r'(?:預約|预约).{0,12}(?:門診|门诊|診所|诊所|醫院|医院)',re.I)
_SOURCES={
    'transport':('mtr-journey-planner','transport-bus-info-2026'),
    'healthcare':('ha-service-guide-2026','ha-gopc-registration-2026'),
}

def guidance_domain(text: str) -> str | None:
    # Classify requests per clause. A later reminder, preference or subsidy
    # cannot suppress an earlier service request. Pure memory/task clauses
    # retain their existing flow, including "remind me to book a clinic".
    welfare = False
    for clause in _CLAUSE_BREAK.split(text):
        if _MEMORY_REQUEST.search(clause):
            continue
        action = _HEALTH_ACTION.search(clause)
        reminder = _REMINDER.search(clause)
        if reminder and (action is None or reminder.start() < action.start()):
            continue
        if action:
            return 'healthcare'
        if _TRANSPORT.search(clause) and _REQUEST.search(clause):
            return 'transport'
        if _WELFARE.search(clause):
            welfare = True
        elif _HEALTHCARE.search(clause) and _REQUEST.search(clause):
            return 'healthcare'
    return 'welfare' if welfare else None

def navigation_resources(domain: str) -> dict:
    allowed=_SOURCES.get(domain,())
    records={r.id:r for r in get_default_resource_service().records}
    bindings=[{'source_id':key,'content_hash':_record_hash(records[key])} for key in allowed if key in records]
    # Reuse card-source reconstruction: reject unsupported URLs or changed refs.
    sources=sanitized_sources({'resource_source_bindings':bindings})
    items=[{'id':s['source_id'],'title':s['title'],'url':s['url'],'verified_at':s['reviewed_at'],
            'effective_date':s['effective_date'],'excerpt':'Official navigation reference only; verify current arrangements with the provider.',
            'conditions':[],'missing_information':['Current routes, fares, availability and individual circumstances have not been checked.'],
            'next_steps':[]} for s in sources]
    keys={s['source_id'] for s in sources}
    return {'items':items,'source_bindings':[b for b in bindings if b['source_id'] in keys],
            'retrieval_mode':'reviewed_navigation_manifest','conflicts':[]}

def render_navigation(domain: str, items: list[dict], user_message: str) -> str:
    zh=bool(re.search(r'[\u3400-\u9fff]',user_message))
    if zh:
        boundary=('我不會計算路線、車費或到站時間，也不會代你叫車、購票或傳送個人資料。'
                  if domain=='transport' else
                  '我不會讀取病歷、提供診斷、估算輪候時間或代你預約，也不會傳送個人資料。此資料庫沒有已核實的專用病歷存取或即時輪候資料。')
        if not items:return '[官方資料交接] '+boundary+'\n暫時沒有足夠的已核實官方入口。請直接向服務機構查詢；我不能確認目前安排。'
        lines=['[官方資料交接 — 僅提供查詢入口]',boundary,
               '以下沿用資料庫原核對日期；本次沒有即時核查安排、票價或名額。復康巴士等專用服務須另向服務機構核實。' if domain=='transport' else
               '以下是一般醫管局／普通科門診查詢入口；不是病歷查閱或成功預約的證明。本次沒有即時核查安排或名額。']
        lines += [f"• {i['title']}\n  {i['url']}\n  資料原核對日期：{i['verified_at']}" for i in items]
        lines += ['下一步：1. 自行開啟適合的官方入口。2. 在官方渠道確認所需服務及目前安排。3. 如有疑問，使用官方網站列出的聯絡方法查詢。AI 回答及個人情況未經核實。']
    else:
        boundary=('I cannot calculate a route, fare or arrival time, order transport, buy tickets or send your personal information.'
                  if domain=='transport' else
                  'I cannot access medical records, diagnose, estimate waiting times, book appointments or send your personal information. This collection has no verified records-access or live waiting-time data.')
        if not items:return '[OFFICIAL NAVIGATION] '+boundary+'\nNo sufficiently verified official reference is available. Please contact the provider directly; current arrangements are unconfirmed.'
        lines=['[OFFICIAL NAVIGATION — reference links only]',boundary,
               'These retain the original review dates. Current arrangements, fares and places have not been checked. Specialist transport needs separate confirmation.' if domain=='transport' else
               'These are general HA/clinic guidance links, not proof of record access or a successful booking. Current arrangements and places have not been checked.']
        lines += [f"• {i['title']}\n  {i['url']}\n  Original review date: {i['verified_at']}" for i in items]
        lines += ['Next steps: 1. Open the appropriate official link yourself. 2. Confirm the service and current arrangements there. 3. Ask the provider through contact details on its official website. The AI answer and individual circumstances are not verified.']
    return '\n'.join(lines)
