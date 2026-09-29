const fs=require('node:fs'),assert=require('node:assert/strict');
let pw;try{pw=require('playwright')}catch{pw=require('C:/Users/kkk/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright')}
(async()=>{
 const browser=await pw.chromium.launch({headless:true,channel:'msedge'});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/reply-style.css',r=>r.fulfill({contentType:'text/css',body:fs.readFileSync('prototype/reply-style.css','utf8')}));
  await page.route('**/api/chat',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({reply:'一二三四五六七八九十一二三四五六七八九十\n\n**这两种情况**的概率一样。\n\n\\[P(A\\mid B)=P(A\\mid\\bar B)\\]'})}));
  await page.goto('http://127.0.0.1:4174');
  await page.locator('#answer-input').fill('测试分句');await page.locator('.yb-send').click();
  await page.waitForSelector('.yb-reply-wait');
  assert.equal(await page.locator('[data-action="help"],[data-action="full-answer"]').count(),0);
  assert.equal(await page.locator('.yb-reply-part:visible').count(),1);
  assert.equal(await page.evaluate(()=>StudentMath.delayFor('一二三四五六七八九十一二三四五六七八九十')),10000);
  await page.waitForTimeout(9000);assert.equal(await page.locator('.yb-reply-part:visible').count(),1);
  await page.waitForTimeout(1300);assert.equal(await page.locator('.yb-reply-part:visible').count(),2);
  await page.reload();await page.waitForSelector('.yb-reply-part');
  assert.equal(await page.locator('.yb-reply-wait').count(),0);
  assert.equal(await page.locator('.yb-reply-part:visible').count(),3);
  assert.equal(await page.locator('.yb-formula .katex').count(),1);
  const widths=await page.locator('.yb-bubble').evaluateAll(parts=>parts.map(p=>p.getBoundingClientRect().width));assert.notEqual(widths[0],widths[1]);
  await page.locator('#answer-input').fill('再次测试');await page.locator('.yb-send').click();await page.waitForSelector('.yb-reply-wait');
  await page.locator('#new-chat').click();assert.equal(await page.locator('.yb-reply-wait').count(),0);
  await page.evaluate(()=>{StudentStore.current().messages=[{role:'teacher',text:'**独立**就是：B是否发生，不改变A的概率。\n\n所以这两个概率要相等。\n\n\\[P(A\\mid B)=P(A\\mid\\bar B)\\]'}];StudentStore.persist('messages')});
  await page.reload();await page.waitForSelector('.yb-reply-part');fs.mkdirSync('prototype/screenshots',{recursive:true});
  await page.screenshot({path:'prototype/screenshots/reply-draft-desktop.png'});
  await page.setViewportSize({width:402,height:874});await page.screenshot({path:'prototype/screenshots/reply-draft-mobile.png'});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  assert.deepEqual(errors,[]);console.log('PASS: 20 Chinese characters = 10s; first bubble immediate; breathing indicator; formulas intact; intrinsic widths; history immediate; navigation cleanup; mobile fit.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
