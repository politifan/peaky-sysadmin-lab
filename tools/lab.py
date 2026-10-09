#!/usr/bin/env python3
# Prepared author CLI. No learner Python programming required.
import argparse, hashlib, json, os, pathlib, re, shlex, socket, subprocess, sys, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1];os.chdir(ROOT)
R=ROOT/'.runtime';R.mkdir(exist_ok=True,mode=0o700)
NODES={'node-a':(22181,18081,11),'node-b':(22182,18082,12),'dc1':(22183,18083,13)}
IMAGE_ROOT='https://cloud.debian.org/images/cloud/trixie/20261001-2618/'
IMAGE='debian-13-genericcloud-amd64-20261001-2618.qcow2'
def run(args,**kw):return subprocess.run(args,check=True,**kw)
def capture(args):return subprocess.check_output(args,text=True)
def write(p,text,mode=0o600):p.write_text(text,encoding='utf-8');p.chmod(mode)
def state():return json.loads((R/'state.json').read_text())
def guard(node):
    s=state();assert node in s['nodes'],'Start the selected node first'
    v=capture(['ssh','-F',str(R/'ssh-config'),node,'cat /etc/peaky-instance']).strip()
    assert v==s['instance'], 'Unexpected VM identity; inspect before changing anything'
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
    assert h.hexdigest()==expected,'Debian image checksum mismatch'
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
        run(args);s['nodes'][n]={'pid':int((folder/'qemu.pid').read_text()),'port':port,'http':http,'ip':f'192.168.77.{ip}'}
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
        guard(n);ssh(n,'test -f /var/lib/peaky-ready');print(n,'ready; console/network fingerprint matched',finger,flush=True)
    print('LAB READY',level,flush=True)
def copy(node,source,dest):
    guard(node);run(['scp','-F',str(R/'ssh-config'),source,node+':'+dest])
def status():
    for n in state()['nodes']:guard(n);ssh(n,'hostname; cat /etc/debian_version; systemctl is-system-running || true; ip -br address')
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
        proc=pathlib.Path('/proc')/str(d['pid'])/'cmdline'
        assert proc.exists() and ('peaky-'+state()['instance']+'-'+n).encode() in proc.read_bytes(),'PID identity changed'
        with socket.socket(socket.AF_UNIX) as sock:sock.connect(str(R/n/'monitor.sock'));sock.sendall(b'quit\n')
    print('Only own QEMU processes stopped. Disks preserved; no reset/deletion performed.')
def main():
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='action',required=True)
    u=sub.add_parser('up');u.add_argument('level',choices=['basic','advanced'])
    sub.add_parser('status');sub.add_parser('down')
    s=sub.add_parser('ssh');s.add_argument('node',choices=NODES);s.add_argument('command',nargs='?')
    c=sub.add_parser('copy');c.add_argument('node',choices=NODES);c.add_argument('source');c.add_argument('destination')
    h=sub.add_parser('http');h.add_argument('--node',choices=NODES,required=True);h.add_argument('--expected',required=True);h.add_argument('--out',required=True)
    a=p.parse_args()
    if a.action=='up':up(a.level)
    elif a.action=='ssh':ssh(a.node,a.command)
    elif a.action=='copy':copy(a.node,a.source,a.destination)
    elif a.action=='http':http(a.node,a.expected,a.out)
    else:globals()[a.action]()
if __name__=='__main__':main()
