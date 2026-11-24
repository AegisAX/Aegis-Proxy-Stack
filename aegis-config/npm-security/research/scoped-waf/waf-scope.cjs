// Compile the installed v1beta1 host policy into NGINX's native lookup table.
// The worker reads the resulting map in memory without a per-request service call.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const yaml = require('js-yaml');

const policy = '/ext/appsec/local_policy.yaml';
const map = '/run/nginx/aegis-waf-scope.conf';
const nginx = '/usr/sbin/nginx';
const http = require('node:http');
const receipt = '/ext/appsec/.aegis-active-policy';
const socket = '/run/nginx/aegis-scope.sock';
function mode(value) {
    switch (value) {
    case 'prevent-learn': case 'prevent': return 1;
    case 'detect-learn': case 'detect': case 'inactive': return 0;
    default: throw new Error('Unrecognized WAF policy mode');
    }
}
function compile(document, confirmed) {
    const policies = document?.policies;
    if (!Array.isArray(policies?.['specific-rules'])) throw new Error('Invalid WAF policy rule list');
    const code = value => mode(value) ? (confirmed ? 1 : 2) : 0;
    const fallback = code(policies.default?.mode);
    const hosts = new Map();
    for (const rule of policies['specific-rules']) {
        if (typeof rule.host !== 'string') throw new Error('Missing WAF rule host');
        const host = rule.host.toLowerCase().replace(/\.$/, '');
        // NGINX hostnames supports exact names and a leading wildcard. Refuse ambiguous
        // policy syntax before activation so an unsupported rule cannot lose protection.
        const name = host.startsWith('*.') ? host.slice(2) : host;
        if (name.length > 253 || !name.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)))
            throw new Error('WAF policy uses a host selector not yet supported by the scope map');
        const value = code(rule.mode);
        if (hosts.has(host) && hosts.get(host) !== value) throw new Error('Conflicting WAF modes for one host');
        hosts.set(host,value);
    }
    // Escape NGINX map keywords when they occur as literal DNS labels.
    const lines = [...hosts].sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0)
        .map(([host,value]) => '    ' + (/^(default|hostnames|volatile|include)$/.test(host) ? '\\\\' : '') + host + ' ' + value + ';');
    return ['map $host $aegis_prevent {','    hostnames;', '    default '+fallback+';', ...lines,
        '}', 'map $server_port $aegis_proxy_scope {',
        '    81 0;', '    default $aegis_prevent;', '}', 'aegis_waf_policy_scope $aegis_proxy_scope;', ''].join('\n');
}
function snapshot() {
    const source = fs.readFileSync(policy);
    const digest = crypto.createHash('sha256').update(source).digest('hex');
    let confirmed = false;
    try {
        const fd = fs.openSync(receipt,fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
        try {
            const stat = fs.fstatSync(fd);
            const age = Date.now() - stat.mtimeMs;
            confirmed = stat.isFile() && stat.size === 65 && age >= -1000 && age < 30000 &&
                fs.readFileSync(fd,'utf8') === digest+'\n';
        } finally { fs.closeSync(fd); }
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const revision = digest + (confirmed ? '-active' : '-pending');
    const config = compile(yaml.load(source.toString('utf8')),confirmed) +
        'server {\n    listen unix:'+socket+';\n    access_log off;\n' +
        '    location = /revision { return 200 "'+revision+'"; }\n    location / { return 404; }\n}\n';
    return {config,revision};
}
function liveRevision() {
    return new Promise(resolve => {
        const req = http.get({socketPath:socket,path:'/revision',agent:false},res=>{
            let text='';
            res.on('data',chunk=>{ text+=chunk; if (text.length>80) res.destroy(); });
            res.on('end',()=>resolve(res.statusCode===200 ? text : ''));
            res.on('error',()=>resolve(''));
        });
        req.setTimeout(1000,()=>req.destroy());
        req.on('error',()=>resolve(''));
    });
}
function readMap() {
    try { return fs.readFileSync(map, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; return undefined; }
}
function publish(data) {
    const temp = path.join(path.dirname(map), '.waf-scope-'+crypto.randomUUID());
    try {
        fs.writeFileSync(temp,data,{flag:'wx',mode:0o644});
        fs.renameSync(temp,map);
    } finally { fs.rmSync(temp,{force:true}); }
}
function nginxCommand(...args) {
    const p = spawnSync(nginx,args,{timeout:10000,encoding:'utf8'});
    if (p.status !== 0) throw new Error('NGINX failed scope configuration check or reload');
}
function startup() {
    const {config} = snapshot();
    if (readMap() !== config) publish(config);
}
async function watch() {
    let lastError, pendingRevision, retryAt=0;
    while (true) {
        try {
            const {config,revision} = snapshot();
            if (readMap() !== config) publish(config);
            if (await liveRevision() !== revision && (pendingRevision !== revision || Date.now() >= retryAt)) {
                pendingRevision=revision;
                retryAt=Date.now()+5000;
                nginxCommand('-t');
                nginxCommand('-s','reload');
            }
            lastError=undefined;
        } catch (error) {
            if (lastError !== error.message) console.error('WAF scope:',error.message);
            lastError=error.message;
        }
        await new Promise(resolve=>setTimeout(resolve,1000));
    }
}
async function awaitPolicy(digest) {
    if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error('Invalid policy revision');
    const until = Date.now()+45000;
    do {
        if (await liveRevision() === digest+'-active') return;
        await new Promise(resolve=>setTimeout(resolve,500));
    } while (Date.now()<until);
    throw new Error('Policy saved. The WAF and proxy have not confirmed this policy revision.');
}
if (require.main === module) {
    if (process.argv[2] === 'startup') startup();
    else if (process.argv[2] === 'watch') watch();
    else if (process.argv[2] === 'validate-stdin') compile(yaml.load(fs.readFileSync(0,'utf8')),false);
    else throw new Error('Expected startup, watch, or validate-stdin');
}
module.exports = {compile,awaitPolicy};
