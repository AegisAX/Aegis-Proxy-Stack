'use strict';

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {EventEmitter} = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const {awaitPolicy} = require('../aegis-config/npm-security/research/scoped-waf/waf-scope.cjs');

const policy = Buffer.from('test policy');
const digest = createHash('sha256').update(policy).digest('hex');

function simulate(t, activeAfter, installed = policy, workerError) {
    let elapsed = 0;
    t.mock.method(require('node:child_process'), 'execFile', (program, args, options, done) => {
        assert.equal(program, '/bin/sh');
        assert.deepEqual(args, ['/app/aegis-waf-ready.sh']);
        queueMicrotask(() => done(workerError));
    });
    t.mock.method(Date, 'now', () => elapsed);
    t.mock.method(global, 'setTimeout', (callback, ms) => {
        elapsed += ms;
        queueMicrotask(callback);
    });
    t.mock.method(fs, 'readFileSync', filename => {
        assert.equal(filename, '/ext/appsec/local_policy.yaml');
        return installed;
    });
    t.mock.method(http, 'get', (options, callback) => {
        assert.equal(options.socketPath, '/run/nginx/aegis-scope.sock');
        const request = new EventEmitter();
        request.setTimeout = () => {};
        queueMicrotask(() => {
            const response = new EventEmitter();
            response.statusCode = 200;
            callback(response);
            response.emit('data', digest + (elapsed >= activeAfter ? '-active' : '-pending'));
            response.emit('end');
        });
        return request;
    });
    return () => elapsed;
}

test('a slow acknowledgement succeeds only after the running revision is active', async t => {
    const elapsed = simulate(t, 56000);
    await awaitPolicy(digest);
    assert.equal(elapsed(), 56000);
});

test('an unavailable agent leaves activation pending with a bounded wait', async t => {
    const elapsed = simulate(t, Infinity);
    await assert.rejects(awaitPolicy(digest), {status:503, public:true});
    assert.equal(elapsed(), 120000);
});

test('a superseded revision conflicts even while it is still running', async t => {
    simulate(t, 0, Buffer.from('newer policy'));
    await assert.rejects(awaitPolicy(digest), {status:409, public:true});
});

test('a confirmed policy cannot report success while a worker is unavailable', async t => {
    simulate(t, 0, policy, new Error('worker channels pending'));
    await assert.rejects(awaitPolicy(digest), {status:503, public:true});
});
