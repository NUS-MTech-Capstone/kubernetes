#!/usr/bin/env python3
"""Derive SSH report tables/charts from sanitized campaign artifacts, offline."""
import argparse
import collections
import datetime as dt
import json
from pathlib import Path


def read(path, fallback=None):
    return json.loads(path.read_text()) if path.exists() else fallback


def epoch(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def quantile(values, fraction):
    if not values: return None
    a=sorted(values); x=(len(a)-1)*fraction; lo=int(x); hi=min(len(a)-1,lo+1)
    return a[lo]+(a[hi]-a[lo])*(x-lo)


def derive(root):
    if not list(root.glob('ssh-campaign-*/*/run.json')): return preflight_result(root)
    rows=[]; series=[]
    for path in sorted(root.glob('ssh-campaign-*/*/run.json')):
        run=read(path); summary=read(path.parent/'summary.json',{}).get('metrics',{})
        metric=lambda name:summary.get(name,{}).get('values',{})
        values=[]; by_second=collections.defaultdict(list)
        for line in (path.parent/'metrics.jsonl').read_text().splitlines() if (path.parent/'metrics.jsonl').exists() else []:
            point=json.loads(line)
            if point.get('type')=='Point' and point.get('metric')=='ddm_terminal_echo_ms' and point['data'].get('tags',{}).get('phase')=='steady':
                value=point['data']['value'];values.append(value)
                by_second[int(epoch(point['data']['time'])//10)*10].append(value)
        probes=metric('ddm_terminal_probe_success{phase:steady}')
        row={'run':str(path.parent.relative_to(root)),'profile':run['script'],'status':run.get('status','PARTIAL'),
             'requestedSessions':run['vus'],'peakConnections':run.get('maxClientConnected'),
             'plateau':run.get('plateau'),'startedAt':run['startedAt'],'endedAt':run.get('endedAt'),
             'echo':{'count':len(values),'p50':quantile(values,.5),'p95':quantile(values,.95),'p99':quantile(values,.99)},
             'probeSuccess':probes.get('rate'),'probeSuccesses':probes.get('passes'),'probeFailures':probes.get('fails'),
             'startMs':metric('ddm_session_start_duration'),'sshReadyMs':metric('ddm_ssh_ready_ms'),
             'connectSuccess':metric('ddm_ws_connect_success'),
             'lifecycleConnectSuccess':metric('ddm_lifecycle_connect_success'),
             'httpFailureRate':metric('http_req_failed{surface:api}').get('rate'),
             'lifecycleSuccess':metric('ddm_lifecycle_success'),
             'timeouts':metric('ddm_terminal_probe_timeouts').get('count',0),
             'unexpectedDisconnects':metric('ddm_ws_unexpected_disconnects').get('count',0),
             'protocolErrors':metric('ddm_terminal_protocol_errors').get('count',0),
             'cleanup':read(path.parent/'recovery.json'), 'abortReason':run.get('abortReason'),
             'failedThresholds':run.get('failedThresholds',[])}
        saved=metric('ddm_terminal_echo_ms{phase:steady}')
        if values and (saved.get('count')!=len(values) or abs(saved['p(95)']-row['echo']['p95'])>.001):
            raise ValueError('Raw echo samples disagree with k6 summary: '+str(path))
        resource=collections.defaultdict(dict)
        for line in (path.parent/'resources.jsonl').read_text().splitlines() if (path.parent/'resources.jsonl').exists() else []:
            sample=json.loads(line)
            for m in sample['data'].get('MetricDataResults',[]):
                for t,v in zip(m.get('Timestamps',[]),m.get('Values',[])):
                    when=epoch(t)
                    if epoch(run['startedAt'])-60<=when<=epoch(run.get('endedAt') or sample['timestamp']):
                        resource[m['Label']][when]=100-v if m['Id']=='target_cpu' else v
        row['resourceMaxima']={label:max(points.values()) for label,points in resource.items() if points}
        row['resourceSamples']={label:len(points) for label,points in resource.items()}
        generators=[json.loads(x) for x in (path.parent/'generator.jsonl').read_text().splitlines()] if (path.parent/'generator.jsonl').exists() else []
        row['generatorMaxCPUOneCore']=max((x['cpuPercentOneCore'] for x in generators if x['cpuPercentOneCore'] is not None),default=None)
        row['generatorMaxRSSKiB']=max((x['rssKiB'] for x in generators if x['rssKiB'] is not None),default=None)
        availability=[json.loads(x) for x in (path.parent/'availability.jsonl').read_text().splitlines()] if (path.parent/'availability.jsonl').exists() else []
        row['availability']={'total':len(availability),'success':sum(x['ok'] for x in availability)}
        events=[json.loads(x) for x in (path.parent/'events.jsonl').read_text().splitlines()] if (path.parent/'events.jsonl').exists() else []
        ready=set(); verified=[]
        for event in events:
            if event['kind']=='ready':ready.add(event['sessionId'])
            elif event['kind']=='disconnected':ready.discard(event['sessionId'])
            if event['kind'] in ('ready','disconnected'):verified.append((epoch(event['timestamp']),len(ready)))
        series.append({'verifiedConnections':verified,'run':row['run'],'resources':resource,'echoP95TenSeconds':{t:quantile(v,.95) for t,v in by_second.items()},
                       'connections':[(epoch(e['timestamp']),e['connected']) for e in events if e['kind'] in ('opened','disconnected')]})
        rows.append(row)
    result={'generatedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'runs':rows,
            'stops':[{'path':str(p.relative_to(root)),**read(p)} for p in sorted(root.glob('ssh-campaign-*/blocked.json'))],
            'interpretation':'Latency percentiles are per run; successful echo latency excludes timed-out probes, whose failures are shown separately. Resource samples are one-minute buckets overlapping the run. CPU and memory are percentages of container limits; target CPU is active percentage. No API-read capacity inference.'}
    (root/'ssh-results.json').write_text(json.dumps(result,indent=2)+'\n')
    plot(root,rows,series)
    return result


def plot(root,rows,series):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.dates as md
    charts=root/'charts';charts.mkdir(exist_ok=True)
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
    date=lambda t:dt.datetime.fromtimestamp(t,dt.timezone.utc).astimezone(dt.timezone(dt.timedelta(hours=8)))
    fig,axes=plt.subplots(2,1,figsize=(11,6.5),sharex=True,layout='constrained')
    for s in series:
        if s['verifiedConnections']:
            x,y=zip(*s['verifiedConnections']);axes[0].step([date(t) for t in x],y,where='post',color='#176B87')
        points=s['echoP95TenSeconds']
        if points:axes[1].plot([date(t) for t in points],list(points.values()),'.-',color='#176B87',markersize=2,linewidth=.8)
    axes[0].set_ylabel('SSH sessions with verified echo');axes[0].set_ylim(bottom=0);axes[0].set_title('Capacity profiles: verified SSH concurrency and terminal echo latency')
    axes[1].axhline(200,color='#B24B3A',linestyle='--',label='Acceptance p95 <200 ms');axes[1].set_ylabel('Echo p95 per 10 s (ms)');axes[1].set_xlabel('Time (SGT)');axes[1].legend(loc='upper left');axes[1].xaxis.set_major_formatter(md.DateFormatter('%H:%M',tz=dt.timezone(dt.timedelta(hours=8))))
    for ax in axes:ax.grid(alpha=.2)
    fig.savefig(charts/'ssh-concurrency-latency.png',dpi=180);plt.close(fig)
    combined=collections.defaultdict(dict)
    for s in series:
        for label,points in s['resources'].items():combined[label].update(points)
    fig,axes=plt.subplots(2,1,figsize=(11,6.5),sharex=True,layout='constrained')
    for label,points in combined.items():
        if label not in ('proxy-dataplane_cpu','proxy-dataplane_memory','target_cpu_idle','target_memory','rds_cpu'):continue
        points=dict(sorted(points.items())); ax=axes[1] if label.endswith('memory') else axes[0]
        ax.plot([date(t) for t in points],list(points.values()),label=label.replace('target_cpu_idle','target CPU active').replace('_',' '),linewidth=1)
    axes[0].axhline(85,color='#B24B3A',linestyle='--',label='CPU guard 85%');axes[1].axhline(80,color='#B24B3A',linestyle='--',label='Memory guard 80%')
    axes[0].set_title('Resources during the SSH campaign');axes[0].set_ylabel('CPU (%)');axes[1].set_ylabel('Memory (%)');axes[1].set_xlabel('Time (SGT)')
    for ax in axes:ax.set_ylim(0,100);ax.grid(alpha=.2);ax.legend(loc='upper left',fontsize=8,ncol=2)
    axes[1].xaxis.set_major_formatter(md.DateFormatter('%H:%M',tz=dt.timezone(dt.timedelta(hours=8))))
    fig.savefig(charts/'ssh-resources.png',dpi=180);plt.close(fig)


def preflight_result(root):
    first=read(root/'preflight.json',{})
    recovery=[json.loads(x) for x in (root/'browser-recovery.jsonl').read_text().splitlines()]
    final=read(root/'final-state.json',{})
    points=[{'timestamp':first['observedAt'],'metadata':first['allActiveSessions'],'capacity':sum(x['activeSessions'] for x in first['capacity'])}]
    points += [{'timestamp':r['timestamp'],'metadata':r['allActiveSessions'],'capacity':sum(x['activeSessions'] for x in r['capacity'])} for r in recovery]
    metrics=collections.defaultdict(dict)
    samples=[read(root/'preflight-resources.json',{})]+[x['resources'] for x in recovery]
    for sample in samples:
        for m in sample.get('MetricDataResults',[]):
            for t,v in zip(m.get('Timestamps',[]),m.get('Values',[])):
                if epoch(t)>=epoch('2026-10-15T07:23:00Z'):
                    metrics[m['Label']][epoch(t)]=100-v if m['Id']=='target_cpu' else v
    maxima={k:max(v.values()) for k,v in metrics.items() if v}
    result={'generatedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'status':'BLOCKED_BEFORE_LOAD',
        'runs':[],'timedSSHRunCount':0,'sshLatencySamples':0,'baselineCompleted':False,
        'browser':read(root/'browser-pre.json'),'stop':read(root/'campaign-stopped.json'),
        'capacityObservations':points,'resourceMaxima':maxima,'resourceSamples':{k:len(v) for k,v in metrics.items()},
        'allRequiredTelemetryFresh':all(x['telemetryFailure'] is None for x in recovery),
        'deploymentStable':first.get('deployments')==final.get('deployment'),
        'scope':'Resources and capacity snapshots describe browser preflight and recovery only; no timed SSH load, latency distribution, repeatability, soak or saturation measurement exists.'}
    (root/'ssh-results.json').write_text(json.dumps(result,indent=2)+'\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.dates as md
    zone=dt.timezone(dt.timedelta(hours=8))
    date=lambda x:dt.datetime.fromtimestamp(x,dt.timezone.utc).astimezone(zone)
    charts=root/'charts';charts.mkdir(exist_ok=True)
    plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
    fig,axes=plt.subplots(2,1,figsize=(10,5.8),layout='constrained',gridspec_kw={'height_ratios':[2,1]})
    times=[date(epoch(p['timestamp'])) for p in points]
    axes[0].plot(times,[p['capacity'] for p in points],'o',color='#B24B3A',label='Accounted active slots')
    axes[0].plot(times,[p['metadata'] for p in points],'x',color='#176B87',label='Active session metadata')
    axes[0].set_title('Browser preflight: capacity remained allocated after session closure')
    axes[0].set_ylabel('Count at sampled times');axes[0].set_yticks([0,1]);axes[0].set_ylim(-.2,1.4)
    axes[0].xaxis.set_major_formatter(md.DateFormatter('%H:%M',tz=zone));axes[0].set_xlabel('15 October 2026 (SGT)');axes[0].legend(loc='upper left',fontsize=9);axes[0].grid(alpha=.2)
    axes[1].axis('off');axes[1].text(.5,.7,'SSH echo latency: unmeasured',ha='center',fontsize=14,weight='bold');axes[1].text(.5,.35,'No timed k6 run started. No p50, p95 or p99 can be calculated.\nThese snapshots do not establish sustained SSH concurrency.',ha='center',fontsize=11)
    fig.savefig(charts/'ssh-preflight-recovery.png',dpi=180);plt.close(fig)
    fig,axes=plt.subplots(2,1,figsize=(10,5.8),sharex=True,layout='constrained')
    for label in ('proxy-dataplane_cpu','proxy-dataplane_memory','target_cpu_idle','target_memory','rds_cpu'):
        values=dict(sorted(metrics[label].items()));ax=axes[1] if label.endswith('memory') else axes[0]
        ax.plot([date(t) for t in values],list(values.values()),'.-',linewidth=1,markersize=3,label=label.replace('target_cpu_idle','target CPU active').replace('_',' '))
    axes[0].set_title('Browser preflight and recovery resources (not a load plateau)')
    axes[0].set_ylabel('CPU (%)');axes[1].set_ylabel('Memory (%)');axes[1].set_xlabel('15 October 2026 (SGT)')
    for ax in axes:ax.grid(alpha=.2);ax.legend(fontsize=8,ncol=2);ax.set_ylim(bottom=0)
    axes[1].xaxis.set_major_formatter(md.DateFormatter('%H:%M',tz=zone))
    fig.savefig(charts/'ssh-preflight-resources.png',dpi=180);plt.close(fig)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory',type=Path);a=p.parse_args()
    result=derive(a.directory);print('Derived',len(result['runs']),'SSH run rows')
