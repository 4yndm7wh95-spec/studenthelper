const assert=require('node:assert/strict'),path=require('node:path');
let playwright;try{playwright=require('playwright')}catch{playwright=require('C:/Users/kkk/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')}
(async()=>{const browser=await playwright.chromium.launch({channel:'msedge',headless:true});try{
 const page=await browser.newPage({viewport:{width:402,height:874}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.nativeEvents=[];window.webkit={messageHandlers:{mathHeight:{postMessage:v=>nativeEvents.push(['height',v])},mathPace:{postMessage:v=>nativeEvents.push(['pace',v])}}}});
 await page.goto('file:///'+path.resolve('ios/WebMath/index.html').replace(/\\/g,'/'));
 await page.evaluate(()=>showMath({text:'**独立**就是B发生与否不改变A的概率。\n\n因此这两个概率相等。\n\n\\[P(A\\mid B)=P(A\\mid\\bar B)\\]',fontSize:16,cards:true,structured:true,paced:true,reduced:false,skip:0}));
 await page.waitForSelector('.yb-reply-part');
 assert.equal(await page.locator('.yb-reply-part:visible').count(),1);
 assert.equal(await page.locator('.yb-bubble.is-lead').count(),1);
 await page.waitForFunction(()=>nativeEvents.some(e=>e[0]==='pace'&&e[1]===true));
 await page.evaluate(()=>showMath({text:'**独立**就是B发生与否不改变A的概率。\n\n因此这两个概率相等。\n\n\\[P(A\\mid B)=P(A\\mid\\bar B)\\]',fontSize:16,cards:true,structured:true,paced:true,reduced:false,skip:1}));
 await page.waitForFunction(()=>document.querySelectorAll('.yb-reply-part:not([hidden])').length===3);
 assert.equal(await page.locator('.yb-bubble.is-formula .katex').count(),1);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
 assert.deepEqual(errors,[]);console.log('PASS: bundled iOS WebMath renders paced Chinese bubbles, highlight, formula, skip, native height callbacks, and 402px width.');
}finally{await browser.close()}})().catch(error=>{console.error(error);process.exitCode=1});
