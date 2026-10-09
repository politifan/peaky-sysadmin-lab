#!/usr/bin/env python3
# Prepared author CLI. No learner Python programming required.
import argparse, hashlib, json, os, pathlib, re, shlex, socket, subprocess, sys, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1];os.chdir(ROOT)
os.umask(0o077)
R=ROOT/'.runtime';R.mkdir(exist_ok=True,mode=0o700)
NODES={'node-a':(22181,18081,11),'node-b':(22182,18082,12),'dc1':(22183,18083,13)}
IMAGE_ROOT='https://cloud.debian.org/images/cloud/trixie/20261001-2618/'
IMAGE='debian-13-genericcloud-amd64-20261001-2618.qcow2'
IMAGE_SHA512='f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d'
def run(args,**kw):return subprocess.run(args,check=True,**kw)
def capture(args):return subprocess.check_output(args,text=True)
def write(p,text,mode=0o600):p.write_text(text,encoding='utf-8');p.chmod(mode)
def file_hash(path):
    h=hashlib.sha256()
    with pathlib.Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
def state():return json.loads((R/'state.json').read_text())
def guard(node):
    s=state();assert node in s['nodes'],'Start the selected node first'
    v=capture(['ssh','-F',str(R/'ssh-config'),node,'printf "%s\\n" "$(cat /etc/peaky-instance)" "$(hostname)"']).strip().splitlines()
    assert v==[s['instance'],node], 'Unexpected VM identity/hostname; inspect before changing anything'
def ssh(node,cmd=None):
    guard(node)
    return run(['ssh','-F',str(R/'ssh-config'),node]+([] if cmd is None else [cmd]))
def up(level):
    assert not (R/'state.json').exists(),'Existing lab: use status/ssh; do not overwrite its disks'
    for tool in ['qemu-img','qemu-system-x86_64','cloud-localds','ssh','ssh-keygen','ssh-keyscan']:
        run(['which',tool],stdout=subprocess.DEVNULL)
    selected=['node-a'] if level=='basic' else list(NODES)
    for n in selected:
        for port in NODES[n][:2]:
            with socket.socket() as sock:sock.bind(('127.0.0.1',port))
    image=R/IMAGE
    if not image.exists():urllib.request.urlretrieve(IMAGE_ROOT+IMAGE,image)
    sums=urllib.request.urlopen(IMAGE_ROOT+'SHA512SUMS',timeout=60).read().decode()
    expected=next(l.split()[0] for l in sums.splitlines() if l.split()[-1].lstrip('*')==IMAGE)
    h=hashlib.sha512()
    with image.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    assert h.hexdigest()==expected==IMAGE_SHA512,'Debian image checksum mismatch'
    print('Official Debian image SHA512 verified:',expected,flush=True)
    run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(R/'student-key')])
    pub=(R/'student-key.pub').read_text().strip();instance=os.urandom(16).hex()
    conf=[];s={'instance':instance,'image_sha512':expected,'nodes':{}}
    for idx,n in enumerate(selected,1):
        port,http,ip=NODES[n];folder=R/n;folder.mkdir()
        user=f'''#cloud-config
hostname: {n}
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - name: student
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: [{pub}]
package_update: true
packages: [nginx, curl, jq, acl, rsync, dnsutils, nftables, sqlite3, lvm2, samba, smbclient, krb5-user, ldap-utils, sudo, openssh-server]
write_files:
  - path: /etc/peaky-instance
    permissions: '0444'
    content: {instance}
runcmd:
  - [sh, -c, "echo PEAKY_HOST_KEY_BEGIN; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub; echo PEAKY_HOST_KEY_END"]
  - [touch, /var/lib/peaky-ready]
'''
        net=f'''version: 2
ethernets:
  nat0:
    match: {{macaddress: '52:54:00:80:00:{idx:02x}'}}
    set-name: nat0
    dhcp4: true
  lan0:
    match: {{macaddress: '52:54:00:77:00:{idx:02x}'}}
    set-name: lan0
    addresses: [192.168.77.{ip}/24]
'''
        write(folder/'user-data',user);write(folder/'meta-data',f'instance-id: {instance}-{n}\nlocal-hostname: {n}\n');write(folder/'network-config',net)
        run(['cloud-localds','--network-config='+str(folder/'network-config'),str(folder/'seed.iso'),str(folder/'user-data'),str(folder/'meta-data')])
        run(['qemu-img','create','-f','qcow2','-F','qcow2','-b',str(image),str(folder/'disk.qcow2'),'12G'])
        accel=['-accel','kvm','-cpu','host'] if os.access('/dev/kvm',os.R_OK|os.W_OK) else ['-accel','tcg','-cpu','max']
        args=['qemu-system-x86_64','-name',f'peaky-{instance}-{n}','-m','2048','-smp','2']+accel+[
            '-drive',f'file={folder}/disk.qcow2,if=virtio,format=qcow2',
            '-drive',f'file={folder}/seed.iso,media=cdrom,readonly=on',
            '-netdev',f'user,id=nat,hostfwd=tcp:127.0.0.1:{port}-:22,hostfwd=tcp:127.0.0.1:{http}-:8080',
            '-device',f'virtio-net-pci,netdev=nat,mac=52:54:00:80:00:{idx:02x}',
            '-netdev','socket,id=lan,mcast=230.0.0.1:17777,localaddr=127.0.0.1',
            '-device',f'virtio-net-pci,netdev=lan,mac=52:54:00:77:00:{idx:02x}',
            '-display','none','-serial',f'file:{folder}/console.log','-monitor',f'unix:{folder}/monitor.sock,server=on,wait=off','-daemonize','-pidfile',str(folder/'qemu.pid')]
        run(args);s['nodes'][n]={'pid':int((folder/'qemu.pid').read_text()),'port':port,'http':http,'ip':f'192.168.77.{ip}','args':args,'disk':str(folder/'disk.qcow2')}
        conf.append(f'Host {n}\n  HostName 127.0.0.1\n  Port {port}\n  User student\n  IdentityFile {R}/student-key\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile {R}/known_hosts\n  BatchMode yes\n  ConnectTimeout 5\n')
    write(R/'state.json',json.dumps(s,indent=2));write(R/'ssh-config','\n'.join(conf));write(R/'known_hosts','')
    for n in selected:
        folder=R/n;deadline=time.monotonic()+1200;finger=None
        while time.monotonic()<deadline:
            log=(folder/'console.log').read_text(errors='replace') if (folder/'console.log').exists() else ''
            m=re.search(r'PEAKY_HOST_KEY_BEGIN.*?(SHA256:[A-Za-z0-9+/]+).*?PEAKY_HOST_KEY_END',log,re.S)
            if m:finger=m[1];break
            time.sleep(3)
        assert finger,'VM not ready; inspect .runtime/'+n+'/console.log'
        key=subprocess.check_output(['ssh-keyscan','-T','5','-t','ed25519','-p',str(NODES[n][0]),'127.0.0.1'],text=True,stderr=subprocess.DEVNULL)
        write(folder/'scanned.pub',key)
        got=capture(['ssh-keygen','-lf',str(folder/'scanned.pub')]);assert finger in got,'SSH fingerprint differs from separate VM console'
        with (R/'known_hosts').open('a') as f:f.write(key)
        guard(n);ssh(n,'test -f /var/lib/peaky-ready')
        # Check actual tools, not only a cloud-init marker; packaging transitions
        # can otherwise leave an apparently ready guest without DNS commands.
        ssh(n,'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl jq acl rsync bind9-dnsutils nftables sqlite3 lvm2 samba smbclient krb5-user ldap-utils sudo openssh-server')
        ssh(n,'command -v dig && command -v smbclient && command -v sqlite3 && command -v getfacl && command -v nft')
        print(n,'ready; required tools and console/network fingerprint matched',finger,flush=True)
    print('LAB READY',level,flush=True)
def copy(node,source,dest):
    guard(node);run(['scp','-F',str(R/'ssh-config'),source,node+':'+dest])
def status():
    for n in state()['nodes']:guard(n);ssh(n,'hostname; cat /etc/debian_version; systemctl is-system-running || true; ip -br address')
def prepare():
    for node in state()['nodes']:
        if node=='dc1':continue
        ssh(node,'install -d -m 0700 /home/student/peaky-setup')
        for name in ['index.txt','list-portal.conf','list-check.sh','list-check.service','list-check.timer','prepare.sh']:
            copy(node,'files/'+name,'/home/student/peaky-setup/'+name)
        ssh(node,'sudo bash /home/student/peaky-setup/prepare.sh')
def domain_init():
    node='dc1';ssh(node,'install -d -m 0700 /home/student/peaky-setup')
    copy(node,'files/domain-init.sh','/home/student/peaky-setup/domain-init.sh')
    ssh(node,'sudo bash /home/student/peaky-setup/domain-init.sh')
def alive(node):
    d=state()['nodes'][node];proc=pathlib.Path('/proc')/str(d['pid'])/'cmdline'
    if not proc.exists() or not proc.read_bytes():return False
    assert ('peaky-'+state()['instance']+'-'+node).encode() in proc.read_bytes(),'PID reused by a different process'
    return True
def stop(node):
    guard(node)
    result=subprocess.run(['ssh','-F',str(R/'ssh-config'),node,'sudo poweroff'])
    assert result.returncode in [0,255],result.returncode
    deadline=time.monotonic()+120
    while alive(node) and time.monotonic()<deadline:time.sleep(1)
    assert not alive(node),'Shutdown not finished; do not copy live disk'
    print(node,'gracefully powered off; disk preserved')
def start(node):
    s=state();assert node in s['nodes'];assert not alive(node),'VM already running'
    d=s['nodes'][node];run(d['args']);d['pid']=int((R/node/'qemu.pid').read_text());write(R/'state.json',json.dumps(s,indent=2))
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        try:guard(node);print(node,'ready after start');return
        except subprocess.CalledProcessError:time.sleep(2)
    raise AssertionError('VM did not restart; inspect console')
def export_vm(node,dest):
    assert node in state()['nodes'];assert not alive(node),'Stop the VM before export'
    p=pathlib.Path(dest).resolve();base=(ROOT/'backups').resolve()
    assert p.is_relative_to(base),'Export must be under own backups/'
    assert not p.exists(),'Refuse replacing an earlier export'
    p.parent.mkdir(exist_ok=True,parents=True,mode=0o700)
    run(['qemu-img','convert','-O','qcow2',state()['nodes'][node]['disk'],str(p)])
    h=file_hash(p)
    write(pathlib.Path(str(p)+'.json'),json.dumps({'node':node,'instance':state()['instance'],'sha256':h,'source_image_sha512':IMAGE_SHA512},indent=2))
    info=json.loads(capture(['qemu-img','info','--output=json',str(p)]));assert 'backing-filename' not in info
    print('EXPORTED standalone disk; keep it private',node,h)
def restore_vm(node,source):
    s=state();assert node in s['nodes'];assert not alive(node),'Stop before selecting restored disk'
    source=pathlib.Path(source).resolve();assert source.is_relative_to((ROOT/'backups').resolve())
    manifest=json.loads(pathlib.Path(str(source)+'.json').read_text())
    assert manifest['node']==node and manifest['instance']==s['instance'],'Wrong node/instance export'
    assert file_hash(source)==manifest['sha256'],'Corrupt VM export'
    info=json.loads(capture(['qemu-img','info','--output=json',str(source)]));assert 'backing-filename' not in info
    target=R/node/('restored-'+str(time.time_ns())+'.qcow2')
    run(['qemu-img','convert','-O','qcow2',str(source),str(target)])
    d=s['nodes'][node];old=d['disk'];d['args']=[a.replace('file='+old+',','file='+str(target)+',') for a in d['args']];d['disk']=str(target)
    write(R/'state.json',json.dumps(s,indent=2));start(node)
    print('RESTORED into separate disk; original disk preserved',node)
def snapshot_vm(node):
    s=state();assert node in s['nodes'];assert not alive(node),'Stop before offline snapshot'
    d=s['nodes'][node];old=d['disk'];target=R/node/('snapshot-'+str(time.time_ns())+'.qcow2')
    run(['qemu-img','create','-f','qcow2','-F','qcow2','-b',old,str(target)])
    d['args']=[a.replace('file='+old+',','file='+str(target)+',') for a in d['args']];d['disk']=str(target)
    write(R/'state.json',json.dumps(s,indent=2));print('Offline disk snapshot created; backing disks preserved',node)
def http(node,expected,out):
    guard(node);url='http://127.0.0.1:'+str(NODES[node][1])+'/index.txt'
    try:
        with urllib.request.urlopen(url,timeout=8) as r:body=r.read();code=r.status
        assert code==200 and body==pathlib.Path(expected).read_bytes(),'Unexpected status or old document content'
        result={'passed':True,'node':node,'status':code,'sha256':hashlib.sha256(body).hexdigest(),'instance':state()['instance']}
    except Exception as e:result={'passed':False,'node':node,'error':str(e)}
    p=pathlib.Path(out);p.parent.mkdir(exist_ok=True,parents=True)
    with p.open('x',encoding='utf-8') as f:json.dump(result,f,indent=2)
    print(json.dumps(result));assert result['passed'],'HTTP check failed (local self-check only)'
def down():
    for n,d in state()['nodes'].items():
        if not alive(n):continue
        with socket.socket(socket.AF_UNIX) as sock:sock.connect(str(R/n/'monitor.sock'));sock.sendall(b'quit\n')
    print('Only own QEMU processes stopped. Disks preserved; no reset/deletion performed.')
def main():
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='action',required=True)
    u=sub.add_parser('up');u.add_argument('level',choices=['basic','advanced'])
    sub.add_parser('status');sub.add_parser('down');sub.add_parser('prepare');sub.add_parser('domain-init')
    for name in ['start','stop','snapshot-vm']:
        t=sub.add_parser(name);t.add_argument('node',choices=NODES)
    for name in ['export-vm','restore-vm']:
        t=sub.add_parser(name);t.add_argument('node',choices=NODES);t.add_argument('path')
    s=sub.add_parser('ssh');s.add_argument('node',choices=NODES);s.add_argument('command',nargs='?')
    c=sub.add_parser('copy');c.add_argument('node',choices=NODES);c.add_argument('source');c.add_argument('destination')
    h=sub.add_parser('http');h.add_argument('--node',choices=NODES,required=True);h.add_argument('--expected',required=True);h.add_argument('--out',required=True)
    a=p.parse_args()
    if a.action=='up':up(a.level)
    elif a.action=='ssh':ssh(a.node,a.command)
    elif a.action=='copy':copy(a.node,a.source,a.destination)
    elif a.action=='http':http(a.node,a.expected,a.out)
    elif a.action=='domain-init':domain_init()
    elif a.action in ['start','stop']:globals()[a.action](a.node)
    elif a.action=='snapshot-vm':snapshot_vm(a.node)
    elif a.action=='export-vm':export_vm(a.node,a.path)
    elif a.action=='restore-vm':restore_vm(a.node,a.path)
    else:globals()[a.action]()
if __name__=='__main__':main()
