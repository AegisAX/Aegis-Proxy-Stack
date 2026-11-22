#!/usr/bin/env python3
"""Rebuild the pinned pip wheel with the pinned pkg_resources implementation for its legacy backend."""
import base64
import csv
import hashlib
import io
import json
from pathlib import Path
import sys
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

folder = Path(sys.argv[1])
def wheel(filename, digest):
    blob=(folder/filename).read_bytes()
    if hashlib.sha256(blob).hexdigest()!=digest:
        raise ValueError(f'Wheel checksum mismatch: {filename}')
    return ZipFile(io.BytesIO(blob))
def replace_once(text, old, new):
    if text.count(old)!=1: raise ValueError(f'Unexpected pinned source: {old[:55]}')
    return text.replace(old,new)

provider=wheel('setuptools-80.10.2-py3-none-any.whl','95b30ddfb717250edb492926c92b5221f7ef3fbcc2b07579bcd4a27da21d0173')
original=wheel('pip-26.3-py3-none-any.whl','f3b60b20ffaadd4415ed7957212a38ac63fa4c5fa375bd0f4a797777940fad13')
version='26.3+aegis.1'
prefix=f'pip-{version}.dist-info/'
files={name.replace('pip-26.3.dist-info/',prefix):original.read(name) for name in original.namelist() if not name.endswith(('/','/RECORD'))}
resources=provider.read('pkg_resources/__init__.py').decode(); start=resources.index('sys.path.extend(((vendor_path');end=resources.index('# capture these',start)
resources=resources[:start]+resources[end:]
packaging_imports='\n'.join('import packaging.'+name for name in ['markers','requirements','specifiers','utils','version'])
resources=replace_once(resources,packaging_imports,'from pip._vendor import packaging\nfrom pip._vendor.packaging import markers, requirements, specifiers, utils, version')
resources=replace_once(resources,'from jaraco.text import','from pip._internal.utils._jaraco_text import')
resources=replace_once(resources,'from platformdirs import','from pip._vendor.platformdirs import')
files['pip/_vendor/pkg_resources/__init__.py']=resources.encode()
license_bytes=provider.read('setuptools-80.10.2.dist-info/licenses/LICENSE')
files['pip/_vendor/pkg_resources/LICENSE']=license_bytes
files[prefix+'licenses/src/pip/_vendor/pkg_resources/LICENSE']=license_bytes
for name,old,new in [('pip/_vendor/vendor.txt','setuptools==70.3.0','setuptools==80.10.2'),(prefix+'METADATA','\nVersion: 26.3\n',f'\nVersion: {version}\n'),('pip/__init__.py','__version__ = "26.3"',f'__version__ = "{version}"')]:
    files[name]=replace_once(files[name].decode(),old,new).encode()
name='pip/_vendor/bom.cdx.json'; sbom=json.loads(files[name]); item=next(x for x in sbom['components'] if x['name']=='setuptools');assert item['version']=='70.3.0';old=item['bom-ref'];new=old.replace('70.3.0','80.10.2');assert old!=new
files[name]=json.dumps(sbom,indent=2).replace(old,new).replace('pkg:pypi/setuptools@70.3.0','pkg:pypi/setuptools@80.10.2').replace('"version": "70.3.0"','"version": "80.10.2"').encode()+b'\n'
record=io.StringIO(newline='');writer=csv.writer(record,lineterminator='\n')
for name,b in sorted(files.items()):
    digest=base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b'=').decode();writer.writerow([name,'sha256='+digest,len(b)])
writer.writerow([prefix+'RECORD','','']);files[prefix+'RECORD']=record.getvalue().encode()
out=folder/f'pip-{version}-py3-none-any.whl'
with ZipFile(out,'w') as archive:
    for name,b in sorted(files.items()):
        entry=ZipInfo(name,date_time=(2026,11,2,0,0,0));entry.compress_type=ZIP_DEFLATED;entry.external_attr=0o100644 << 16;archive.writestr(entry,b)
print(out.name, hashlib.sha256(out.read_bytes()).hexdigest())
