from pathlib import Path
from copy import deepcopy
import argparse,json,hashlib
from docx import Document
from docx.shared import Inches,Pt,RGBColor
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT,WD_CELL_VERTICAL_ALIGNMENT

p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);p.add_argument('evidence',type=Path);a=p.parse_args()
assert a.source!=a.output
source_hash=hashlib.sha256(a.source.read_bytes()).hexdigest()
d=Document(a.source);P=list(d.paragraphs);T=list(d.tables)
r=json.loads((a.evidence/'ssh-results.json').read_text());assert r['timedSSHRunCount']==0

def replace(p,text):
    fmt=deepcopy(p.runs[0]._r.rPr) if p.runs and p.runs[0]._r.rPr is not None else None
    for c in list(p._p):
        if c.tag!=qn('w:pPr'):p._p.remove(c)
    run=p.add_run(text)
    if fmt is not None:run._r.insert(0,fmt)
    return run

def cell(t,row,col,text):
    c=t.cell(row,col);replace(c.paragraphs[0],text)
    for p in list(c.paragraphs[1:]):c._tc.remove(p._p)

def para(anchor,text,style='Normal',bold=False):
    p=anchor.insert_paragraph_before(text,style)
    if style=='Normal':
        for run in p.runs:run.font.name='Arial';run.font.size=Pt(11);run.bold=bold
        p.paragraph_format.space_after=Pt(7)
    return p

def table(anchor,headers,rows,widths):
    t=d.add_table(rows=1,cols=len(headers));anchor._p.addprevious(t._tbl)
    t.alignment=WD_TABLE_ALIGNMENT.CENTER;t.autofit=False
    pr=t._tbl.tblPr
    borders=OxmlElement('w:tblBorders')
    for name in ('top','left','bottom','right','insideH','insideV'):
        b=OxmlElement('w:'+name);b.set(qn('w:val'),'single');b.set(qn('w:sz'),'4');b.set(qn('w:color'),'D9D9D9');borders.append(b)
    pr.append(borders)
    for j,w in enumerate(widths):t.columns[j].width=Inches(w)
    for i,row in enumerate([headers]+rows):
        cells=t.rows[0].cells if i==0 else t.add_row().cells
        trPr=t.rows[i]._tr.get_or_add_trPr();trPr.append(OxmlElement('w:cantSplit'))
        if i==0:trPr.append(OxmlElement('w:tblHeader'))
        for j,text in enumerate(row):
            c=cells[j];c.width=Inches(widths[j]);c.vertical_alignment=WD_CELL_VERTICAL_ALIGNMENT.CENTER
            c.text=str(text);tcpr=c._tc.get_or_add_tcPr()
            margins=OxmlElement('w:tcMar')
            for side,value in (('top','90'),('bottom','90'),('left','90'),('right','90')):
                el=OxmlElement('w:'+side);el.set(qn('w:w'),value);el.set(qn('w:type'),'dxa');margins.append(el)
            tcpr.append(margins)
            if i==0:
                sh=OxmlElement('w:shd');sh.set(qn('w:fill'),'E7E6E6');tcpr.append(sh)
            for pp in c.paragraphs:
                pp.paragraph_format.space_after=Pt(0);pp.paragraph_format.line_spacing=1.05
                pp.alignment=WD_ALIGN_PARAGRAPH.LEFT if j in (0,len(headers)-1) else WD_ALIGN_PARAGRAPH.CENTER
                for rr in pp.runs:rr.font.name='Arial';rr.font.size=Pt(10.5);rr.bold=i==0;rr.font.color.rgb=RGBColor(0,0,0)
    para(anchor,'')
    return t

def caption(anchor,text):
    p=para(anchor,text,'Caption1');p.paragraph_format.keep_with_next=True;return p

def image(anchor,name,text):
    pp=para(anchor,'');pp.paragraph_format.keep_with_next=True
    pp.add_run().add_picture(str(a.evidence/'charts'/name),width=Inches(6.25))
    cp=para(anchor,text,'Caption1');cp.paragraph_format.keep_with_next=False

replace(P[3],'15 October 2026')
replace(P[250],'Completed load results cover read-only APIs. The 15 October SSH campaign stopped during preflight because capacity did not fully release after session closure. The 40-session target, SSH echo latency, repetitions, soak and saturation remain unmeasured (Sections 17.18–17.19).')
replace(P[270],P[270].text.replace('API load','API load and stopped SSH preflight'))
replace(P[776],'Section 17.19 separates historical API-load results from the stopped SSH preflight and its resource and capacity-recovery evidence.')
replace(P[844],P[844].text.replace('API load','API load, bounded SSH preflight'))
replace(P[921],'Performance evidence separates API reads from interactive SSH. The completed 7 October API profiles use authenticated Agentic and Audit reads. The 15 October SSH-only campaign was prepared to measure real PTYs through normal Cognito/ALB authentication, STS capabilities, version-one APIs and the public direct WebSocket route.')
replace(P[924],'The read workloads use authenticated access to health, alert, incident and audit APIs. They do not measure interactive SSH concurrency. The SSH campaign uses the existing 50-session configuration and a ceiling of min(40, configured capacity − 10 − existing active sessions), preserving other users’ sessions and fixed resource limits.')
anchor=P[925]
para(anchor,'The planned SSH matrix starts with a five-minute baseline and one-session lifecycle smoke. Discovery uses 5, 10, 20, 30 and 40 sessions, each with a 60-second staggered ramp and five-minute plateau. Every session must establish SSH and return its unique echo before the common plateau begins; actual sustained concurrency is recorded.')
para(anchor,'Repeatability adds two runs at 20 sessions and at the highest passing level, deduplicating identical levels. A 20-minute soak follows at the highest passing level. Lifecycle load uses five virtual users for three minutes, repeated three times. Separate start/close stress uses five users, 30-second ramps, a two-minute plateau and a global limit of two starts per second.')
para(anchor,'A probe sends one unique marker every two seconds, waits at most 1.5 seconds and clears the input with Ctrl-U without executing a command. Only matching output packets count. Passing plateaus require echo p95 <200 ms, session-start API p95 <2 s, connection/probe success ≥99%, HTTP failures <1%, and no unexpected disconnect or protocol error. Start API timing, first verified SSH echo readiness and steady echo timing remain separate; readiness includes the scheduled probe delay.')
para(anchor,'Authentication, unexpected disconnect, deployment/readiness/restart change, telemetry older than 180 seconds, consumed reserve or failed cleanup stops the campaign. Rolling guards stop on >1% probe failures, echo p95 >1 s or >5% HTTP failures; two consecutive one-minute samples above 85% CPU or 80% memory also stop testing. Only an ordinary latency failure permits lower-level work after recovery. Cleanup must close attributed sessions and release their capacity, with a one-minute cooldown extending to five minutes.')
replace(P[926],'Historical API results (7 October 2026): k6 v2.1.0 used the authenticated public route, 10 virtual users, five minutes of measurement and one-second pacing per run. Thresholds were p50 and p95 <1,000 ms, checks >99% and HTTP failures <1%.')
replace(P[929],'All three completed API-read runs passed with zero HTTP failures (37,856 requests). Planned repetition coverage remains incomplete: Agentic reads completed 1/3 runs and Audit reads 2/3. These results establish neither SSH capacity nor terminal echo latency.')
replace(P[932],'All 185 authenticated probes succeeded during the three historical API-load windows. No resource-limit breach or restart was recorded in those completed runs. Later missing target telemetry stopped the historical campaign. These probes do not establish long-term availability.')
anchor=P[941]
para(anchor,'SSH campaign outcome on 15 October 2026','Heading 3')
lead=para(anchor,'The SSH campaign stopped before timed load. Browser preflight verified authenticated echo, detach/rejoin with retained input, new owner echo and read-only observation. Both attributed sessions were CLOSED, including the initial session from a popup that the browser tool could not expose. However, zero active session metadata coexisted with one accounted capacity slot beyond the five-minute recovery limit. No k6 workload or five-minute baseline completed.')
d.add_comment(lead.runs, 'V13 update from the 15 October retained evidence. The cleanup stopping rule prevented SSH capacity and latency measurement; historical API results are retained separately.',author='DenDenMushi report update',initials='DDM')
caption(anchor,'Table 17.16 SSH concurrency latency and error assessment')
table(anchor,['Scenario','Planned shape','Done','Latency and errors','Result'],[
['Browser preflight','One controlled lifecycle','1','Echo and read-only behavior verified; timing not sampled.','Partial'],
['Automated smoke','1 SSH session','0','No timed samples.','Not run'],
['Discovery','5, 10, 20, 30, 40 SSH sessions','0','Sustained concurrency, echo/start p50/p95/p99 and error rates unavailable.','Not run'],
['Repeatability','20 and highest passing level, 3 runs each','0','No repeatability result.','Not run'],
['Soak','Highest passing level, 20 min','0','No duration result.','Not run'],
['Lifecycle load','5 VUs × 3 min × 3 runs','0','No lifecycle-load error rate.','Not run'],
['Start/close stress','5 VUs, 30/120/30 s, ≤2 starts/s','0','No start-stress throughput or latency.','Not run'],
], [1.05,1.45,.65,2.15,.95])
para(anchor,'No SSH latency distribution, probe-success percentage, timeout count or load-generator utilization is reported: the corresponding timed samples do not exist. Browser viewport/fullscreen controls did not change observed dimensions, so browser resize remains unverified in this attempt. Tabs closed before delayed disconnect indicators were verified; authoritative metadata closure was checked separately. The planned automated resize, protocol termination and post-campaign browser checks were not executed.')
caption(anchor,'Table 17.17 Resources and recovery during browser preflight only')
m=r['resourceMaxima']; rows=[]
for label,name in [('proxy-dataplane','Proxy Dataplane'),('proxy-controlplane','Proxy Control Plane'),('session-manager','Session Manager'),('audit-service','Audit Service'),('sts','STS')]:
 rows.append([name,f"{m[label+'_cpu']:.2f}%",f"{m[label+'_memory']:.2f}%",('500m CPU / 128 MiB' if label=='proxy-dataplane' else '250m CPU / 128 MiB')])
rows += [['Target host',f"{m['target_cpu_idle']:.2f}%",f"{m['target_memory']:.2f}%",'Host utilization; one target'],['RDS',f"{m['rds_cpu']:.2f}%",'Not required','DB instance CPU']]
table(anchor,['Resource','Peak CPU','Peak memory','Denominator'],rows,[1.55,.9,1.05,2.75])
para(anchor,'Recovery failed beyond five minutes: zero active session metadata remained, but one capacity slot was still accounted for. All 12 workloads were ready, with unchanged pod identities, restart counts and images.')
para(anchor,'Container percentages use configured limits. Target CPU is 100 minus idle; host memory and RDS CPU use their native denominators. The exports contain 14 one-minute samples per container series, 13 per target series and 12 for RDS, with all 13 required series fresh at recovery checks. These are preflight observations, not a load plateau or proof of headroom at 40 sessions.')
image(anchor,'ssh-preflight-recovery.png','Figure 17.10 Sampled capacity mismatch after browser session closure. No timed SSH latency samples were collected.')
image(anchor,'ssh-preflight-resources.png','Figure 17.11 Resource observations during browser preflight and recovery. Container CPU/memory use limits; axes differ between CPU and memory.')
para(anchor,'Source inspection identifies a plausible cause: Session Manager preserves the greater of stored and heartbeat-reported counts, while idempotent close decrements only on the first transition. A heartbeat sampled before runtime closure can therefore restore an already released slot. This is an inference consistent with the retained evidence, not a captured database interleaving. The proposed regression fixture compiles against the deployed revision; its real-PostgreSQL execution was blocked by Docker disk exhaustion. No service patch, database repair or deployment restart was performed.')
para(anchor,'The prepared harness revision is 80f8244016bdfe2dcdebcf7bee4739c7c73ecd5b, with passing CI. The final harness adds baseline rejection of capacity-accounting mismatches and passes 31 local tests (8 Node, 23 Python), plus inspection of all seven profiles. The observed GitOps revision is c8d5f7c02b76aebb25ea1457761c283bf35dc09a. Image digests and source labels are retained in the evidence index; no deployed image changed for this attempt.')
para(anchor,'A01, A07 and R13 remain partial: the 40-session target, terminal latency, repeatability, soak and saturation are still unmeasured. Historical API repetition gaps also remain. Any future measurement must first resolve capacity recovery and pass a fresh preflight. Conclusions are limited to one deployed configuration and one target host; planned synthetic PTY echo would not measure browser rendering, heavy command workloads or long-term reliability.')
ep=para(anchor,'Evidence: ')
link=OxmlElement('w:hyperlink');link.set(qn('r:id'),ep.part.relate_to('https://github.com/NUS-MTech-Capstone/kubernetes/tree/main/documentation/evidence/ssh-2026-10-15','http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink',is_external=True))
lr=OxmlElement('w:r');lt=OxmlElement('w:t');lt.text='Retained SSH preflight results and source identities';lr.append(lt);link.append(lr);ep._p.append(link)
replace(P[942],'Table 17.18 LLM judge evaluation framework')
replace(P[948],'Table 17.19 Initial synthetic model comparison')
replace(P[1068],'Browser workflows demonstrate governed access and incident review. Argo history records release and rollback reconciliation. CloudWatch exports cover the historical API workload and the stopped SSH preflight, whose unresolved capacity recovery prevents a concurrency claim.')
replace(P[1093],'DenDenMushi delivers a governed SSH platform and a bounded incident workflow on AWS. The terminal path remains direct, with explicit user capability and runtime ownership. Incident assistance adds reviewable evidence and proposals while Agent Control Plane retains approved execution. The project demonstrates traceable CI, GitOps promotion and rollback, refreshed unit coverage, API-read results and controlled agent evaluations. The 15 October SSH preflight exposed unresolved capacity accounting after closure; the campaign stopped as required. Interactive SSH capacity through 40 sessions, echo latency, soak, saturation and planned repetition coverage are not yet validated.')
replace(P[1102],'Section 15.7 shows correlated CloudWatch logs and alarm recovery. Section 17.19 separates historical API-load graphs from SSH preflight resource snapshots and the failed capacity-recovery result.')
cell(T[14],1,2,'Interactive I/O is demonstrated in Section 4.4 and the 15 October browser preflight. SSH echo percentiles remain unmeasured (Section 17.19).')
cell(T[14],3,2,'Unmeasured. The SSH campaign stopped during preflight cleanup; no 40-session plateau completed.')
cell(T[15],1,2,'185/185 probes in the historical API-load windows; no SSH load-window availability result.')
cell(T[20],6,1,'Functional echo and rejoin were verified. Timed echo p50/p95/p99 and sustained SSH concurrency remain unmeasured after the cleanup stop (Section 17.19).')
cell(T[70],5,1,'3 API-read runs; SSH preflight stopped')
cell(T[70],5,2,'37,856 API requests, zero HTTP failures; API repetitions incomplete. SSH timed load unmeasured because capacity did not release.')
cell(T[103],6,2,'10 CI coverage results, PostgreSQL jobs, contracts, 3 API-read runs, failed SSH preflight cleanup and controlled agent evaluations.')
cell(T[104],15,1,'API-read and guarded interactive SSH test profiles')
# Preserve all unchanged package content and the input bytes.
d.core_properties.modified=__import__('datetime').datetime(2026,10,15,8,0,0)
d.core_properties.comments='V13: SSH campaign preflight, capacity recovery failure and explicit measurement limits.'
d.save(a.output)
assert hashlib.sha256(a.source.read_bytes()).hexdigest()==source_hash
print(json.dumps({'output':str(a.output),'sourceSHA256':source_hash,'paragraphs':len(d.paragraphs),'tables':len(d.tables)}))
