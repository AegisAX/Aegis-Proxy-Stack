"""Read the compiler's real Ninja dependency database and compare the linked archive objects."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('ninja', type=Path)
parser.add_argument('objects', type=Path)
parser.add_argument('receipt', type=Path)
args = parser.parse_args()
headers = {'boost/regex/v5/basic_regex_creator.hpp', 'boost/regex/v5/regex_format.hpp'}
archive = args.objects / 'components/security_apps/waap/waap_clib/libwaap_clib.a'
target = 'nodes/http_transaction_handler/cp-nano-http-transaction-handler'

def ninja(*params):
    return subprocess.check_output([args.ninja, '-C', args.objects, '-t', *params], text=True)

members = subprocess.check_output(['ar', 't', archive], text=True).splitlines()
output = ninja('deps')
matching = {}
obj = None
for line in output.splitlines():
    if line and not line.startswith(' '):
        name, _, description = line.partition(':')
        obj = name if 'waap_clib.dir/' in name and name.endswith('.o') and 'deps mtime' in description else None
    elif obj and (header := line.strip().removeprefix('/usr/include/')) in headers:
        matching.setdefault(obj, set()).add(header)
if len(matching) != 31 or set.union(*matching.values()) != headers:
    raise SystemExit('Unexpected WAF header-to-object dependency set')
for obj in matching:
    name = Path(obj).name
    if members.count(name) != 1 or subprocess.check_output(['ar', 'p', archive, name]) != (args.objects / obj).read_bytes():
        raise SystemExit('WAF object is missing from the linked archive: ' + obj)
if 'libwaap_clib.a' not in ninja('commands', target).splitlines()[-1]:
    raise SystemExit('The final link rule does not reference the verified WAF archive')
report = {'objects': {k: sorted(v) for k, v in matching.items()},
          'deps_sha256': hashlib.sha256((args.objects / '.ninja_deps').read_bytes()).hexdigest(),
          'ninja_deps_output_sha256': hashlib.sha256(output.encode()).hexdigest(),
          'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
with args.receipt.open('x') as fp:
    json.dump(report, fp, indent=2)
    fp.write('\n')
