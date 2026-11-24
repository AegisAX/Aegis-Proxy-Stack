"""Package a byte-verified WAF adapter on the tested private-core base image."""
import argparse
from pathlib import Path
import shutil
import subprocess
import uuid

import freeze

BASE = 'sha256:27e9761752565d071a5873c19266499fc868a1cf263d039507b256600745b4b5'
HANDLER = '5f3ce9ecdd2ca373d6dff95c5dab350385d6af8e35b144ba6bdee3a233712ebf'
CORE = 'ed48ffa38660dba539fc742ba1871a7f6040ff0ecf405592898591a21167d21b'
INSTALLER = 'b429da985090a8e969a62aeeb98acc1b6b7c5e71d194c94836cb3be7c6163275'

def image_file(image, filename):
    return subprocess.check_output(['docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
                                    '--read-only', '--cap-drop', 'ALL', '--entrypoint', 'cat', image, filename])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('transport', type=Path)
    parser.add_argument('new_output', type=Path)
    args = parser.parse_args()
    elf = (args.transport / 'cp-nano-http-transaction-handler').read_bytes()
    core = (args.transport / 'libaegis_waf_core.so').read_bytes()
    freeze.require(freeze.sha(elf) == HANDLER and freeze.sha(core) == CORE, 'Unexpected WAF build')
    freeze.require(image_file(BASE, '/usr/lib/cpnano/libaegis_waf_core.so') == core, 'Unexpected base library')
    destination = '/' + freeze.INSTALLER
    installer = freeze.update_installer(image_file(freeze.PARENT, destination), elf, INSTALLER)
    output = args.new_output.resolve()
    output.mkdir(mode=0o700)
    (output / 'installer').write_bytes(installer)
    for name in ['agent-entrypoint.sh', 'agent-scope-ack.sh']:
        shutil.copyfile(Path(__file__).with_name(name), output/name)
    tag = 'aegis-waf-qa:' + uuid.uuid4().hex
    subprocess.run(['docker', 'tag', BASE, tag], check=True)
    (output / 'Dockerfile').write_text(
        f'FROM {tag}\nCOPY --chmod=0755 installer {destination}\n'
        'COPY --chmod=0755 agent-scope-ack.sh /usr/local/bin/aegis-agent-scope-ack\n'
        'COPY --chmod=0755 agent-entrypoint.sh /usr/local/bin/aegis-agent-entrypoint\n'
        'ENTRYPOINT ["/usr/local/bin/aegis-agent-entrypoint"]\nCMD ["/cp-nano-agent"]\n')
    try:
        subprocess.run(['docker','build','--network','none','--iidfile',str(output/'image.id'),str(output)],check=True)
        image = (output/'image.id').read_text().strip()
        freeze.require(image_file(image, destination) == installer, 'Packaged installer differs from verified input')
    finally:
        subprocess.run(['docker','image','rm',tag], check=True)

if __name__ == '__main__':
    main()
