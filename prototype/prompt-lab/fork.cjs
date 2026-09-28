const fs=require('node:fs'),path=require('node:path');
const [source,target,prompt,count]=process.argv.slice(2);
const original=JSON.parse(fs.readFileSync(path.join(__dirname,source+'.json'),'utf8'));
const output={...original,prompt:fs.readFileSync(prompt,'utf8'),turns:original.turns.slice(0,Number(count)),forkedFrom:{source,turns:Number(count)}};
fs.writeFileSync(path.join(__dirname,target+'.json'),JSON.stringify(output,null,2));
