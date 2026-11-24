'use strict';
const assert = require('node:assert/strict');
const {compile} = require('../aegis-config/npm-security/research/scoped-waf/waf-scope.cjs');
function document(rules, fallback='inactive') {
    return {policies:{default:{mode:fallback},'specific-rules':rules}};
}
const scopes = document([
    {host:'Prevent.example.test.',mode:'prevent-learn'},
    {host:'detect.example.test',mode:'detect-learn'},
    {host:'off.example.test',mode:'inactive'},
    {host:'*.protected.example.test',mode:'prevent-learn'},
]);
const pending = compile(scopes,false);
const active = compile(scopes,true);
for (const [map,code] of [[pending,2],[active,1]]) {
    for (const name of ['prevent.example.test','*.protected.example.test']) {
        assert.ok(map.includes('    '+name+' '+code+';'));
    }
    for (const name of ['detect.example.test','off.example.test','default']) {
        assert.ok(map.includes('    '+name+' 0;'));
    }
}
assert.ok(compile(document([],'prevent-learn'),false).includes('    default 2;'));
assert.equal(compile(document([...scopes.policies['specific-rules']].reverse()),true),active);
assert.throws(()=>compile(document([{host:'prevent.example.test',mode:'unexpected'}]),true));
assert.throws(()=>compile(document([{host:'bad host',mode:'inactive'}]),true));
assert.throws(()=>compile(document([
  {host:'example.test',mode:'prevent-learn'},{host:'example.test.',mode:'inactive'}
]),true));
console.log('WAF policy scope checks passed');
