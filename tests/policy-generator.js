const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { promisify } = require('node:util');
const test = require('node:test');

test('policy publication preserves a working policy on API failures', async t => {
    const work = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-policy-'));
    t.after(() => fs.rmSync(work, { recursive: true, force: true }));
    const file = path.join(work, 'local_policy.yaml');
    const program = path.resolve(__dirname, '../aegis-config/scripts/policy_generator.js');
    const host = { id: 1, domain_names: ['protected.invalid'], meta: { openappsec: { enabled: true } } };
    let hosts = [host];
    let token = { token: 'fixture' };
    let status = 200;
    const server = http.createServer((req, res) => {
        res.setHeader('content-type', 'application/json');
        if (req.url === '/tokens') return res.end(JSON.stringify(token));
        assert.equal(req.url, '/nginx/proxy-hosts');
        res.statusCode = status;
        res.end(JSON.stringify(hosts));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const run = () => promisify(execFile)(process.execPath, [program], {
        env: { ...process.env, POLICY_FILE: file, NPM_USER: 'test', NPM_PASS: 'fixture',
            NPM_API: 'http://127.0.0.1:' + server.address().port }
    });
    fs.writeFileSync(file, '', { mode: 0o640 });
    await run();
    const previous = fs.readFileSync(file, 'utf8');
    assert.match(previous, /protected\.invalid/);
    assert.equal(fs.statSync(file).mode & 0o777, 0o640);
    for (const cause of ['outage', 'invalid response', 'incomplete host', 'invalid token']) {
        status = cause === 'outage' ? 503 : 200;
        hosts = cause === 'invalid response' ? {} : cause === 'incomplete host' ? [{}] : [];
        token = cause === 'invalid token' ? {} : { token: 'fixture' };
        await assert.rejects(run, { code: 1 });
        assert.equal(fs.readFileSync(file, 'utf8'), previous, cause);
    }
    token = { token: 'fixture' };
    await run();
    assert.match(fs.readFileSync(file, 'utf8'), /specific-rules: \[\]/);
    assert.deepEqual(fs.readdirSync(work), ['local_policy.yaml']);
    const manual = 'manual-origin-rule';
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('specific-rules: []', 'specific-rules:\n    - name: ' + manual));
    hosts = [{ id: 2, domain_names: ['native.invalid'], use_openappsec: true, openappsec_mode: 'detect-learn', minimum_confidence: 'high' }];
    await run();
    const native = fs.readFileSync(file, 'utf8');
    assert.match(native, /manual-origin-rule/);
    assert.match(native, /native\.invalid/);
    assert.match(native, /detect-learn/);
    hosts = [{ id: 2, domain_names: ['native.invalid'], meta: {} }];
    await assert.rejects(run, { code: 1 });
    assert.equal(fs.readFileSync(file, 'utf8'), native);
    hosts = [{ ...host, use_openappsec: false }];
    await assert.rejects(run, { code: 1 });
    assert.equal(fs.readFileSync(file, 'utf8'), native);
});
