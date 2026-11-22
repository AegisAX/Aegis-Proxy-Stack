const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const load = createRequire('/app/package.json');
async function main() {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'tar-api-'));
    try {
        fs.writeFileSync(path.join(temp, 'probe.txt'), 'normal archive round-trip');
        for (const pkg of ['node-pre-gyp','@mapbox/node-pre-gyp','node-gyp','sqlite3','cacache']) {
            const loadFrom = createRequire(load.resolve(`${pkg}/package.json`));
            const tar = loadFrom('tar');
            assert.equal(fs.readFileSync(loadFrom.resolve('tar'), 'utf8'), fs.readFileSync(require.resolve('/usr/lib/node_modules/npm/node_modules/tar'), 'utf8'));
            assert.equal(typeof tar.extract, 'function');
            const dest = fs.mkdtempSync(path.join(temp, 'dest-'));
            const archive = path.join(dest, 'sample.tar.gz');
            await tar.create({ cwd:temp, gzip:true, file:archive }, ['probe.txt']);
            await tar.extract({file:archive,cwd:dest});
            assert.equal(fs.readFileSync(path.join(dest,'probe.txt'),'utf8'), 'normal archive round-trip');
        }
        const bcrypt = load('bcrypt');
        assert.equal(await bcrypt.compare('test-value', await bcrypt.hash('test-value', 4)), true);
        const sqlite = load('sqlite3');
        const db = new sqlite.Database(':memory:');
        await new Promise((resolve,reject) => db.get('SELECT 9 AS n', (err,row) => err || row.n !== 9 ? reject(err || Error('sqlite query')) : resolve()));
        await new Promise((resolve,reject) => db.close(err => err ? reject(err) : resolve()));
        console.log('PASS five consumer archive round-trips, bcrypt native and SQLite in-memory query');
    } finally { fs.rmSync(temp, {recursive:true,force:true}); }
}
main().catch(err => { console.error(err); process.exitCode=1; });
