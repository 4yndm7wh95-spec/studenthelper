const assert=require('node:assert/strict');
let p;try{p=require('playwright')}catch{p=require('C:/Users/kkk/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')}
(async()=>{
 const b=await p.chromium.launch({channel:'msedge',headless:true});try{
 const page=await b.newPage({viewport:{width:1200,height:800}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:4174');
 const legacy=String.raw`先用定义：P(A|B) = P(AB)/P(B)，P(\bar A|\bar B) = 1 - P(A|\bar B)。`;
 const latex=String.raw`用互补关系：
\[P(\bar A\mid\bar B)=1-P(A\mid\bar B)\]
代入条件，试着整理这个等式。`;
 await page.evaluate(texts=>{for(const text of texts)StudentStore.current().messages.push({role:'teacher',text});StudentStore.persist('messages')},[legacy,latex]);
 await page.waitForTimeout(450);
 assert.equal(errors.length,0);assert.equal(await page.locator('.katex-error').count(),0);
 assert.ok(await page.locator('.katex-mathml mover').count()>=4,'bars must render as accents');
 assert.ok(await page.locator('.yb-bubble.is-formula .katex').count()>=1);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
 await page.screenshot({path:'prototype/screenshots/opus-real-formulas.png'});
 console.log('PASS: legacy unwrapped probability formulas, display LaTeX, overbars and formula cards.');
 }finally{await b.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
