const http = require('node:http');
const fs = require('node:fs');
const {randomUUID} = require('node:crypto');
const hosts = {prevent:'smoke.example.test', detect:'detect.example.test', off:'off.example.test'};
const scenario = process.argv[2];
if (!['ready','unavailable','recovered'].includes(scenario)) process.exit(2);
async function probe(host, method, path, expectedStatus, expectedVisits) {
    const marker = randomUUID();
    const status = await new Promise((resolve, reject) => {
        const req = http.request({host:'127.0.0.1',port:80,method,path,agent:false,headers:{
            host: hosts[host], 'x-stage-mark':marker,
            ...(method === 'POST' ? {'content-length':'7', 'content-type':'text/plain'} : {})
        }}, res => { res.resume(); res.once('end', () => resolve(res.statusCode)); res.once('error', reject); });
        req.once('error', reject);
        req.setTimeout(6000, () => req.destroy(new Error('proxy timed out')));
        req.end(method === 'POST' ? 'fixture' : undefined);
    });
    const visits = fs.readFileSync('/tmp/stage-origin.log','utf8').split('\n').filter(value => value===marker).length;
    if (status !== expectedStatus || visits !== expectedVisits) throw new Error(
        [scenario,host,method,path,'HTTP',status,'origin',visits,'expected',expectedStatus,expectedVisits].join(' '));
    return {host, method, path, status, visits};
}
(async () => {
    const rows=[];
    for (const host of Object.keys(hosts)) {
        const unavailable = host === 'prevent' && scenario === 'unavailable';
        for (const method of ['GET','POST']) rows.push(await probe(host,method,'/health-probe',unavailable?503:200,unavailable?0:1));
    }
    rows.push(await probe('prevent','GET','/policy-deny-probe',scenario==='unavailable'?503:403,0));
    console.log(JSON.stringify({scenario,rows}));
})().catch(e=>{console.error(e.message);process.exitCode=1});
