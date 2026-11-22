/**
 * Aegis Policy Generator
 * Generates open-appsec local_policy.yaml based on NPM Proxy Hosts.
 */

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

// --- [Configuration Injection] ---
const CONFIG = {
    NPM_API: process.env.NPM_API || 'http://localhost:81/api',
    IDENTITY: process.env.NPM_USER,
    SECRET: process.env.NPM_PASS,
    POLICY_FILE: process.env.POLICY_FILE || '../policy/local_policy.yaml',
    MODE: process.env.APPSEC_MODE || 'prevent-learn',
    CONFIDENCE: process.env.APPSEC_CONFIDENCE || 'medium'
};

// ANSI Codes for Logging
const STYLE = {
    INFO: '\x1b[46m\x1b[37m\x1b[1m INFO \x1b[0m',
    DONE: '\x1b[42m\x1b[37m\x1b[1m DONE \x1b[0m',
    FAIL: '\x1b[41m\x1b[37m\x1b[1m FAIL \x1b[0m',
    WARN: '\x1b[43m\x1b[37m\x1b[1m WARN \x1b[0m'
};

// Validation
if (!CONFIG.IDENTITY || !CONFIG.SECRET) {
    console.error(`   ${STYLE.FAIL} Missing NPM Credentials (NPM_USER, NPM_PASS).`);
    process.exit(1);
}

// [TEMPLATE] Base Policy Structure
const templateStr = `
policies:
  default:
    triggers:
    - appsec-default-log-trigger
    mode: inactive
    practices:
    - webapp-default-practice
    custom-response: appsec-default-web-user-response
  specific-rules: []

practices:
  - name: webapp-default-practice
    web-attacks:
      max-body-size-kb: 1000000
      max-header-size-bytes: 102400
      max-object-depth: 40
      max-url-size-bytes: 32768
      minimum-confidence: high
      override-mode: inactive
      protections:
        csrf-protection: inactive
        error-disclosure: inactive
        non-valid-http-methods: false
        open-redirect: inactive
    anti-bot:
      injected-URIs: []
      validated-URIs: []
      override-mode: inactive
    snort-signatures:
      configmap: []
      override-mode: inactive
    openapi-schema-validation:
      configmap: []
      override-mode: inactive

log-triggers:
  - name: appsec-default-log-trigger
    access-control-logging:
      allow-events: false
      drop-events: true
    additional-suspicious-events-logging:
      enabled: true
      minimum-severity: high
      response-body: false
      response-code: true
    appsec-logging:
      all-web-requests: false
      detect-events: true
      prevent-events: true
    extended-logging:
      http-headers: false
      request-body: false
      url-path: true
      url-query: true
    log-destination:
      cloud: false
      stdout:
        format: json

custom-responses:
  - name: appsec-default-web-user-response
    mode: response-code-only
    http-response-code: 403
`;

// Reference Objects for Cloning
const referenceObjects = {
    practice: {
        name: "npm-managed-practice-proxyhost-X",
        "web-attacks": {
            "max-body-size-kb": 1000000,
            "max-header-size-bytes": 102400,
            "max-object-depth": 40,
            "max-url-size-bytes": 32768,
            "minimum-confidence": "medium",
            "override-mode": "inactive",
            protections: {
                "csrf-protection": "inactive",
                "error-disclosure": "inactive",
                "non-valid-http-methods": false,
                "open-redirect": "inactive"
            }
        },
        "anti-bot": { "injected-URIs": [], "validated-URIs": [], "override-mode": "inactive" },
        "snort-signatures": { configmap: [], "override-mode": "inactive" },
        "openapi-schema-validation": { configmap: [], "override-mode": "inactive" }
    },
    logTrigger: {
        name: "npm-managed-log-trigger-proxyhost-X",
        "access-control-logging": { "allow-events": false, "drop-events": true },
        "additional-suspicious-events-logging": { enabled: true, "minimum-severity": "high", "response-body": false },
        "appsec-logging": { "all-web-requests": false, "detect-events": true, "prevent-events": true },
        "extended-logging": { "http-headers": false, "request-body": false, "url-path": false, "url-query": false },
        "log-destination": { cloud: false, stdout: { format: "json" } }
    }
};

// --- [Main Logic] ---

async function apiRequest(endpoint, options) {
    const response = await fetch(`${CONFIG.NPM_API}/${endpoint}`, {
        ...options,
        redirect: 'error',
        signal: AbortSignal.timeout(15000)
    });
    if (!response.ok) throw new Error(`NPM ${endpoint} returned HTTP ${response.status}`);
    return response.json();
}

async function getToken() {
    const data = await apiRequest('tokens', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ identity: CONFIG.IDENTITY, secret: CONFIG.SECRET })
    });
    if (typeof data?.token !== 'string' || !data.token) throw new Error('NPM returned no access token');
    return data.token;
}

async function getHosts(token) {
    const hosts = await apiRequest('nginx/proxy-hosts', {
        headers: { Authorization: `Bearer ${token}` }
    });
    if (!Array.isArray(hosts) || !hosts.every(host =>
        host && Number.isSafeInteger(host.id) && host.id > 0 &&
        Array.isArray(host.domain_names) && host.domain_names.length > 0 &&
        host.domain_names.every(domain => typeof domain === 'string' && domain.trim() !== '') &&
        (host.meta == null || (typeof host.meta === 'object' && !Array.isArray(host.meta))) &&
        (typeof host.use_openappsec === 'boolean' || typeof host.meta?.openappsec?.enabled === 'boolean') &&
        (host.use_openappsec === undefined || typeof host.use_openappsec === 'boolean') &&
        (host.meta?.openappsec === undefined || typeof host.meta.openappsec?.enabled === 'boolean') &&
        (host.use_openappsec === undefined || host.meta?.openappsec === undefined ||
            host.use_openappsec === host.meta.openappsec.enabled)
    ) || new Set(hosts.map(host => host.id)).size !== hosts.length) {
        throw new Error('NPM returned an incomplete proxy host list');
    }
    return hosts;
}

function publishPolicy(target, original, output) {
    // Rename on the same filesystem so readers see either complete version.
    const previous = fs.statSync(target, { throwIfNoEntry: false });
    const directory = fs.mkdtempSync(path.join(path.dirname(target), '.aegis-policy-'));
    const pending = path.join(directory, 'policy');
    try {
        fs.writeFileSync(pending, output, { flag: 'wx', mode: 0o600 });
        if (previous) {
            const created = fs.statSync(pending);
            if (previous.uid !== created.uid || previous.gid !== created.gid) {
                fs.chownSync(pending, previous.uid, previous.gid);
            }
        }
        fs.chmodSync(pending, previous ? previous.mode & 0o777 : 0o640);
        if (readPolicy(target) !== original) throw new Error('Policy changed during synchronization');
        fs.renameSync(pending, target);
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

function readPolicy(target) {
    try {
        return fs.readFileSync(target, 'utf8');
    } catch (error) {
        if (error.code === 'ENOENT') return null;
        throw error;
    }
}

async function generatePolicy() {
    console.log(`   ${STYLE.INFO} Starting Policy Generation...`);
    // Detailed config logging removed per user request

    const configured = path.resolve(CONFIG.POLICY_FILE);
    const target = fs.existsSync(configured) ? fs.realpathSync(configured) : configured;
    const original = readPolicy(target);
    const token = await getToken();
    const hosts = await getHosts(token);

    console.log(`   ${STYLE.INFO} Found ${hosts.length} proxy hosts in NPM.`);

    const basePolicy = yaml.load(original?.trim() ? original : templateStr);
    const rules = basePolicy?.policies?.['specific-rules'];
    const practices = basePolicy?.practices;
    const triggers = basePolicy?.['log-triggers'];
    if (![rules, practices, triggers].every(Array.isArray)) throw new Error('Invalid existing WAF policy');
    const keep = new Set();
    const hostIds = new Set(hosts.map(host => String(host.id)));
    function upsert(list, object) {
        keep.add(object.name);
        const previous = list.find(item => item.name === object.name);
        if (previous) Object.assign(previous, object);
        else list.push(object);
    }
    
    // Filter hosts where openappsec is enabled
    const activeHosts = hosts.filter(h => h.use_openappsec ?? h.meta.openappsec.enabled);
    console.log(`   ${STYLE.INFO} open-appsec enabled hosts: ${activeHosts.length}`);

    if (activeHosts.length === 0) {
        console.log(`   ${STYLE.WARN} No active hosts found. Policy will be empty.`);
    }

    activeHosts.forEach(host => {
        const id = host.id;
        const mode = host.openappsec_mode ?? host.meta?.openappsec?.mode ?? CONFIG.MODE;
        const confidence = host.minimum_confidence ?? host.meta?.openappsec?.minimum_confidence ??
            host.meta?.openappsec?.confidence ?? CONFIG.CONFIDENCE;
        if (!['prevent-learn', 'detect-learn', 'prevent', 'detect'].includes(mode) ||
            !['low', 'medium', 'high', 'critical'].includes(confidence)) {
            throw new Error('Unrecognized WAF policy mode or minimum confidence');
        }
        
        const specificRuleName = `npm-managed-specific-rule-proxyhost-${id}`;
        const practiceName = `npm-managed-practice-proxyhost-${id}`;
        const logTriggerName = `npm-managed-log-trigger-proxyhost-${id}`;

        // 1. Create Practice
        const practice = structuredClone(practices.find(item => item.name === practiceName) || referenceObjects.practice);
        practice.name = practiceName;
        practice['web-attacks']['override-mode'] = mode;
        practice['web-attacks']['minimum-confidence'] = confidence;
        upsert(practices, practice);

        // 2. Create Log Trigger
        const trigger = structuredClone(triggers.find(item => item.name === logTriggerName) || referenceObjects.logTrigger);
        trigger.name = logTriggerName;
        upsert(triggers, trigger);

        // 3. Create Specific Rules (Mapping Domains)
        host.domain_names.forEach((domain, idx) => {
            const ruleName = idx > 0 ? `${specificRuleName}.${idx}` : specificRuleName;
            upsert(rules, {
                host: domain,
                name: ruleName,
                triggers: [logTriggerName],
                mode: mode,
                practices: [practiceName]
            });
        });
    });

    for (const list of [rules, practices, triggers]) {
        for (let index = list.length - 1; index >= 0; index--) {
            const name = list[index].name;
            const managed = /^npm-managed-(?:specific-rule|practice|log-trigger)-proxyhost-(\d+)(-\d+)?(?:\.\d+)?$/.exec(name);
            if (managed && !keep.has(name) && (!managed[2] || !hostIds.has(managed[1]))) list.splice(index, 1);
        }
    }
    const yamlStr = yaml.dump(basePolicy, { lineWidth: -1, noRefs: true });
    const finalOutput = `# Generated by Aegis Policy Controller at ${new Date().toISOString()}\n${yamlStr}`;
    
    publishPolicy(target, original, finalOutput);
    console.log(`   ${STYLE.DONE} Policy generated at ${CONFIG.POLICY_FILE}`);
}

generatePolicy().catch(error => {
    console.error(`   ${STYLE.FAIL} Policy generation failed:`, error.message);
    process.exitCode = 1;
});
