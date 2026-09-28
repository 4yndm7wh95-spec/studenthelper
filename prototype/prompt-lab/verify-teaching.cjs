const fs=require('node:fs'),assert=require('node:assert/strict'),path=require('node:path');
const teaching=require('../teaching-instructions.cjs');
assert.equal(teaching.instructions([{role:'user',content:'明白了'},{role:'assistant',content:'继续'}]),teaching.base);
assert.ok(teaching.instructions([{role:'user',content:'带我做题'}]).endsWith(teaching.opening));
const messages=[],turns=[];
async function ask(text){messages.push({role:'user',content:text});const res=await fetch('http://127.0.0.1:4174/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages}),signal:AbortSignal.timeout(95000)});assert.ok(res.ok,'Teaching request failed: '+res.status);const body=await res.json();assert.ok(body.reply);messages.push({role:'assistant',content:body.reply});turns.push({student:text,reply:body.reply,model:body.model});console.log(body.reply);return body.reply}
(async()=>{
 const first=await ask(fs.readFileSync(path.join(__dirname,'q24.txt'),'utf8'));
 assert.ok(!first.includes('frac')&&!first.includes('\\['),'The first turn must not start with a formula block');
 assert.ok(first.length<160,'Opening is too long');
 const next=await ask('明白了，竖线是什么意思？');
 assert.ok(next.length<180,'A single symbol should not trigger a lecture');
 const wrong=await ask('那如果B发生时A的概率是0.4，B不发生时是0.6，也算独立吧？');
 assert.match(wrong,/不独立|不算|不对|不是/,'Must not endorse wrong independence claim');
 assert.ok(wrong.length<180,'Correction should stay local');
 fs.writeFileSync(path.join(__dirname,'web-integration.json'),JSON.stringify({turns},null,2));
 console.log('PASS: deployed prompt, short opening, local symbol explanation, incorrect-answer correction.');
})().catch(error=>{console.error(error.message);process.exitCode=1});
