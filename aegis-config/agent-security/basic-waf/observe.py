"""Sample the frozen WAF under ordinary loopback GET requests in an explicitly named disposable lab."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import time

AGENT = 'sha256:688af57069acc05bc6389a50e47b8c7a7401a4b457681ca587c16669bcbc7e52'
NPM = 'sha256:58da2f5a21c96723e2bcf7379604bdae063e1bc112da8a89697424a29340991a'
ELF = 'a4d07f54fe3c3f5c553aad98550e9980ebe57b7f1213bf3f2b9e40f111e323c2'
MODEL = 'fa59e952a0559376ba3b5a90211881a4b0bfd15f47dbb30101587c8365064e87'
GIB = 1024 ** 3
WORKERS = """
set -eu
target=/etc/cp/HttpTransactionHandler/cp-nano-http-transaction-handler
test ! -e /advanced-model/open-appsec-advanced-model.tgz
echo "$2  /etc/cp/conf/waap/waap.data" | sha256sum -c - >/dev/null
echo "$1  $target" | sha256sum -c - >/dev/null
n=0
for exe in /proc/[0-9]*/exe; do
    path=$(readlink "$exe" 2>/dev/null) || continue
    case "$path" in
        "$target") echo "$1  $exe" | sha256sum -c - >/dev/null; n=$((n+1));;
        "$target (deleted)") exit 1;;
    esac
done
test "$n" -eq 16
"""


def verify(condition, name):
    if not condition:
        raise ValueError(name)


def command(*args, stdin=None, timeout=20, cwd=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True, cwd=cwd,
                          timeout=timeout, check=True).stdout.strip()


def meta(service):
    fmt = '{{.Id}} {{.Image}} {{.State.Status}} {{.State.Health.Status}} {{.State.Pid}} {{.RestartCount}} {{.State.OOMKilled}}'
    return command('docker', 'inspect', '--format', fmt, service).split()


def inspect_lab(lab, project):
    verify(project.startswith('wafsoak-') and lab == lab.resolve(strict=True), 'expected disposable lab')
    pair = {}
    labels = set()
    for service, image in [('agent', AGENT), ('npm', NPM)]:
        ident = command('docker', 'compose', '--project-directory', str(lab), 'ps', '-q', service, cwd=lab)
        def prop(field):
            return json.loads(command('docker','inspect','--format','{{json '+field+'}}',ident))
        tags = prop('.Config.Labels')
        verify(prop('.Id') == ident and tags['com.docker.compose.project'] == project and
               Path(tags['com.docker.compose.project.working_dir']).resolve() == lab and
               tags['com.docker.compose.service'] == service, 'unexpected Compose owner')
        pair[service] = meta(ident)
        verify(pair[service][1:4] == [image, 'running', 'healthy'], 'image or health mismatch')
        verify(not prop('.HostConfig.Privileged') and not prop('.HostConfig.PidMode') and
               prop('.HostConfig.IpcMode') != 'host' and not any(prop('.NetworkSettings.Ports').values()), 'host namespace or port exposure')
        for name in prop('.NetworkSettings.Networks'):
            network = json.loads(command('docker', 'network', 'inspect', name))[0]
            verify(network['Internal'] and network['Labels']['com.docker.compose.project'] == project,
                   'expected project-specific internal network')
        for mount in prop('.Mounts'):
            verify(mount['Type'] == 'volume', 'expected private disposable volumes')
            volume = json.loads(command('docker','volume','inspect',mount['Name']))[0]
            owner = (volume['Labels'] or {}).get('com.docker.compose.project')
            anonymous = len(mount['Name']) == 64 and 'com.docker.volume.anonymous' in (volume['Labels'] or {})
            verify(owner == project or anonymous, 'volume owner mismatch')
            labels.add(mount['Name'])
    for volume in labels:
        ids = command('docker', 'ps', '-aq', '--no-trunc', '--filter', 'volume=' + volume).splitlines()
        owners = command('docker', 'inspect', '--format', '{{index .Config.Labels "com.docker.compose.project"}}', *ids)
        verify(set(owners.splitlines()) == {project}, 'shared volume detected')
    verify(command('docker','inspect','--format','{{.HostConfig.IpcMode}}',pair['npm'][0]) ==
           'container:' + pair['agent'][0], 'NPM does not share IPC with the dedicated agent')
    return pair


def check_workers(agent):
    command('docker','exec','-i',agent,'sh','-s','--',ELF,MODEL,stdin=WORKERS,timeout=30)


def get(npm, tls=False):
    path = '/tls-probe' if tls else '/health-probe'
    options = ['--http2','--cacert','/data/smoke.crt','--resolve','smoke.example.test:443:127.0.0.1',
               '-w',' %{http_version}','https://smoke.example.test' + path] if tls else [
                   '-H','Host: smoke.example.test','http://127.0.0.1' + path]
    answer = command('docker','exec',npm,'curl','-fsS','--max-time','5',*options)
    verify(answer == 'aegis-smoke ' + path + (' 2' if tls else ''), 'unexpected synthetic HTTP response')


def fields(path):
    return dict((k,int(v)) for k,v in (row.split() for row in path.read_text().splitlines()))


def sample(agent, output):
    pid = int(meta(agent)[4])
    group = next(s[3:] for s in Path(f'/proc/{pid}/cgroup').read_text().splitlines() if s.startswith('0::'))
    cg = Path('/sys/fs/cgroup') / group.lstrip('/')
    workers = {}
    for row in command('docker','top',agent,'-eo','pid,rss,comm').splitlines()[1:]:
        pid, rss, comm = row.split()[:3]
        if comm.startswith('cp-nano-http-tr'):
            start = Path('/proc',pid,'stat').read_text().rsplit(')',1)[1].split()[19]
            workers[pid+'@'+start] = int(rss)*1024
    verify(len(workers) == 16, 'expected 16 WAF workers')
    mem = int((cg/'memory.current').read_text())
    used = mem-fields(cg/'memory.stat').get('inactive_file',0)
    avail = next(int(s.split()[1])*1024 for s in Path('/proc/meminfo').read_text().splitlines() if s.startswith('MemAvailable:'))
    cpu = [int(x) for x in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
    return dict(utc=datetime.now(timezone.utc).isoformat(),time=time.monotonic(),workers=workers,working_set=used,
                memory_current=mem,memory_events=fields(cg/'memory.events'),available=avail,disk=shutil.disk_usage(output).free,
                cpu_usec=fields(cg/'cpu.stat')['usage_usec'],host_total=sum(cpu),host_idle=sum(cpu[3:5]))


def run(args):
    lab = args.lab.resolve(strict=True)
    pair = inspect_lab(lab,args.project)
    agent, npm = pair['agent'][0], pair['npm'][0]
    check_workers(agent)
    if args.phase == 'inspect':
        print('Exact images, isolated pair and 16 basic-model WAF workers verified.')
        return
    out = args.output
    out.mkdir(mode=0o700,exist_ok=False)
    total, spacing = (900,2) if args.phase=='initial' else (172800,30)
    start = time.monotonic()
    next_sample = next_deep = next_request = start
    first = prev = None
    hot = successes = samples = 0
    result = dict(agent_image_id=AGENT,npm_image_id=NPM,elf_sha256=ELF,phase=args.phase,passed=False)
    try:
        with (out/'samples.jsonl').open('x', buffering=1) as stream:
            while True:
                now = time.monotonic()
                if now >= next_sample or now-start >= total:
                    row = sample(agent,out)
                    samples += 1
                    if first is None:
                        first = row
                    if prev:
                        gap = row['time']-prev['time']
                        verify(0 < gap <= 120, 'sampling continuity lost')
                        host_cpu = 100*(1-(row['host_idle']-prev['host_idle'])/max(1,row['host_total']-prev['host_total']))
                        agent_cpu = (row['cpu_usec']-prev['cpu_usec'])/(gap*10000)
                        hot = hot+1 if agent_cpu>150 or host_cpu>90 else 0
                    stream.write(json.dumps(row)+'\n')
                    prev = row
                    verify(hot<3 and min(row['disk']/2,row['available'])>=GIB, 'host resource threshold reached')
                    verify(row['working_set']<=first['working_set']+GIB//2, 'memory growth threshold reached')
                    verify(row['workers'].keys()==first['workers'].keys() and
                           all(row['memory_events'][k]==first['memory_events'][k] for k in ('oom','oom_kill')),
                           'worker continuity or OOM')
                    verify(all(meta(info[0])==info for info in pair.values()), 'running pair changed')
                    next_sample = now+30
                if now >= next_deep:
                    check_workers(agent)
                    get(npm,tls=True)
                    next_deep = now+1800
                if now-start >= total:
                    verify(successes>=int(total/spacing*0.98), 'incomplete request count')
                    result['passed'] = True
                    break
                if now >= next_request:
                    get(npm)
                    successes += 1
                    next_request = now+spacing
                time.sleep(max(0,min(next_sample,next_deep,next_request,start+total)-time.monotonic()))
    finally:
        result.update(http_ok=successes,samples=samples,elapsed_seconds=round(time.monotonic()-start,2))
        partial=out/'result.tmp'
        partial.write_text(json.dumps(result,indent=2)+'\n')
        partial.replace(out/'result.json')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lab',type=Path,help='Dedicated Compose directory, private volumes and internal network')
    parser.add_argument('project',help='Exact disposable Compose project name beginning with wafsoak-')
    parser.add_argument('phase',choices=['inspect','initial','long'])
    parser.add_argument('output',type=Path,help='New result directory, unused for inspect')
    run(parser.parse_args())
