"""Write an untagged Docker image archive from the exact parent and verified installed WAF ELF."""
import argparse
import copy
import gzip
import hashlib
import io
import json
import math
from pathlib import Path
import subprocess
import tarfile
import tempfile

PARENT = 'sha256:f0aabe74c1d1d6a2a676fe39fa10d233bcdefe657ae9047e06ef474fc4567329'
RESULT = 'sha256:688af57069acc05bc6389a50e47b8c7a7401a4b457681ca587c16669bcbc7e52'
INSTALLED = 'a4d07f54fe3c3f5c553aad98550e9980ebe57b7f1213bf3f2b9e40f111e323c2'
OLD = 'fc2805aa465cad82abae94a45625443bc7853817aacc60704bf8835306de8cf7'
INSTALLER = 'nano-service-installers/install-cp-nano-service-http-transaction-handler.sh'
MEMBER = './bin/cp-nano-http-transaction-handler'


def require(condition, msg):
    if not condition:
        raise ValueError(msg)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pack(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()


def add(tar, name, contents, mode=0o644):
    member = tarfile.TarInfo(name)
    member.mode, member.size = mode, len(contents)
    tar.addfile(member, io.BytesIO(contents))


def update_installer(blob, elf):
    require(sha(blob) == 'c7d9f7efd52a08d6814cde7888f6009992e8e50c8948a296bfc98170a97f47e9', 'Unexpected parent installer')
    start = blob.index(b'\x1f\x8b\x08')
    header, old = blob[:start], blob[start:]
    result = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(old), mode='r:gz') as src, tarfile.open(fileobj=result, mode='w', format=tarfile.GNU_FORMAT) as dst:
        names = src.getnames()
        require(len(names) == len(set(names)) == 64 and MEMBER in names, 'Unexpected installer inventory')
        for item in src:
            updated = copy.copy(item)
            contents = src.extractfile(item) if item.isfile() else None
            if item.name == MEMBER:
                require(item.isfile() and sha(contents.read()) == OLD, 'Unexpected original WAF ELF')
                delta = len(elf) - item.size
                contents, updated.size = io.BytesIO(elf), len(elf)
            dst.addfile(updated, contents)
    new = gzip.compress(result.getvalue(), compresslevel=9, mtime=0)
    # These fields are part of the upstream makeself format. Exact final installer SHA also
    # checks all 63 unchanged entries, their archive metadata and the replacement checksums.
    for key, fn in [(b'CRCsum', lambda b: subprocess.check_output(['cksum'], input=b).split()[0]),
                    (b'MD5', lambda b: hashlib.md5(b).hexdigest().encode()),
                    (b'filesizes', lambda b: str(len(b)).encode())]:
        original = key + b'="' + fn(old) + b'"'
        require(header.count(original) == 1, 'Unexpected makeself checksum field')
        header = header.replace(original, key + b'="' + fn(new) + b'"')
    require(header.count(b'15718') == 5, 'Unexpected makeself size checks')
    header = header.replace(b'15718', str(15718 + max(0, math.ceil(delta / 1024)) + 4).encode())
    installer = header + new
    require(sha(installer) == '73de7db602db5a61c26a529d3c0c0523481ba0462e0e7c2e7feee4a13091fb2b', 'Installer digest mismatch')
    return installer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('installed_elf', type=Path)
    parser.add_argument('output_tar', type=Path)
    args = parser.parse_args()
    require(args.installed_elf.is_file() and not args.installed_elf.is_symlink(), 'Expected a regular installed ELF')
    require(not args.output_tar.exists() and not args.output_tar.is_symlink(), 'Output already exists')
    elf = args.installed_elf.read_bytes()
    require(sha(elf) == INSTALLED, 'ELF must match the candidate that passed functional validation')
    src = subprocess.check_output(['docker','run','--rm','--pull','never','--network','none','--read-only',
                                   '--cap-drop','ALL','--security-opt','no-new-privileges','--entrypoint','cat',PARENT,'/'+INSTALLER])
    installer = update_installer(src, elf)
    layer = io.BytesIO()
    with tarfile.open(fileobj=layer, mode='w', format=tarfile.GNU_FORMAT) as archive:
        add(archive, INSTALLER, installer, 0o755)
    raw = layer.getvalue()
    require(sha(raw) == '9a2977743728fa1406a20d375d79dad1945f250deb9928837408a120d9776696', 'Layer digest mismatch')
    with tempfile.TemporaryDirectory(dir=args.output_tar.parent) as temp:
        base, target = Path(temp)/'base.tar', Path(temp)/'candidate.tar'
        subprocess.run(['docker','image','save','--output',base,PARENT],check=True)
        with tarfile.open(base) as source, tarfile.open(target, 'w') as dest:
            manifests = json.load(source.extractfile('manifest.json'))
            require(len(manifests) == 1, 'Expected one parent manifest')
            m = manifests[0]
            parent_config = source.extractfile(m['Config']).read()
            require('sha256:' + sha(parent_config) == PARENT, 'Wrong parent image config')
            config = json.loads(parent_config)
            for name in [m['Config'], *m['Layers']]:
                dest.addfile(source.getmember(name), source.extractfile(name))
            config['created'] = '2026-11-21T03:52:00Z'
            config['history'].append({'created': config['created'], 'created_by':'Replace the HTTP transaction handler with the verified public basic-model build and backported Boost.Regex headers'})
            config['rootfs']['diff_ids'].append('sha256:' + sha(raw))
            cfg = pack(config)
            require('sha256:' + sha(cfg) == RESULT, 'Final image config digest mismatch')
            add(dest, 'postlink-config.json', cfg)
            add(dest, 'postlink-layer.tar', raw)
            add(dest, 'manifest.json', pack([{'Config':'postlink-config.json','Layers':[*m['Layers'],'postlink-layer.tar'],'RepoTags':[]}]))
        # An exclusive hard link publishes the complete archive without replacing prior work.
        args.output_tar.hardlink_to(target)
    print(RESULT)


if __name__ == '__main__':
    main()
