const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');
function locate(name, from) {
    for(const root of createRequire(path.join(from,'package.json')).resolve.paths(name) || []) {
        const candidate=path.join(root,name);
        if(fs.existsSync(path.join(candidate,'package.json'))) return fs.realpathSync(candidate);
    }
    throw Error(`Dependency missing: ${name}`);
}
function install(name, target, from, branch = new Set()) {
    const source=locate(name,from);
    if (branch.has(source)) return;
    const pkg=JSON.parse(fs.readFileSync(path.join(source,'package.json')));
    fs.rmSync(target,{recursive:true,force:true}); fs.mkdirSync(path.dirname(target),{recursive:true});
    fs.cpSync(source,target,{recursive:true, filter:(item)=>item!==path.join(source,'node_modules')});
    const next=new Set(branch);next.add(source);
    for(const dep of Object.keys(pkg.dependencies || {})) install(dep,path.join(target,'node_modules',dep),source,next);
}
for(const [name,target] of [['basic-ftp','/app/node_modules/basic-ftp'],['minimatch','/app/node_modules/minimatch'],['minimatch','/usr/lib/node_modules/npm/node_modules/minimatch'],['glob','/usr/lib/node_modules/npm/node_modules/glob']]) install(name,target,'/locked');
