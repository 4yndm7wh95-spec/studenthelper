const assert = require('node:assert/strict');
let playwright; try { playwright = require('playwright'); } catch { playwright = require('C:/Users/kkk/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'); }
async function course(page, name) {
  await page.locator('[data-action="add-course"]').click();
  await page.locator('#course-name').fill(name);
  await page.locator('#create-course').click();
  await page.waitForFunction(name=>StudentStore.current().course===name,name);
  await page.waitForSelector('.yb-welcome');
}
async function rename(page, id, name) {
  await page.locator('[data-action="session-menu"][data-session="'+id+'"]').click();
  await page.locator('#popover-root [data-action="rename-session"]').click();
  await page.locator('#session-name').fill('   ');
  assert.equal(await page.locator('#save-session-name').isDisabled(), true);
  await page.locator('#session-name').fill(name);
  await page.locator('#save-session-name').click();
  await page.waitForSelector('#dialog[open]', {state:'hidden'});
}
async function deleteCourse(page, name, cancel = false) {
  await page.locator('[data-action="course-menu"][data-course="'+name+'"]').click();
  await page.locator('[data-action="delete-course"]').click();
  if (cancel) await page.locator('#dialog [data-action="close-dialog"]').last().click();
  else await page.locator('#confirm-delete-course').click();
  await page.waitForSelector('#dialog[open]', {state:'hidden'});
}
(async()=>{
  const browser = await playwright.chromium.launch({channel:'msedge',headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1440,height:900}}), errors = [];
    page.on('pageerror',error=>errors.push(error.message));
    await page.route('**/api/chat',async route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({reply:'先看这一步。'})}));
    await page.goto('http://127.0.0.1:4174');
    assert.deepEqual(await page.evaluate(()=>StudentStore.state.courses), []);
    await rename(page, 1, '我的普通聊天');
    await page.locator('#answer-input').fill('第一条消息'); await page.locator('.yb-send').click(); await page.waitForSelector('.yb-teacher');
    assert.equal(await page.locator('#top-title').innerText(), '我的普通聊天', 'Sending must preserve a manually chosen name');
    await page.reload();
    assert.equal(await page.locator('#top-title').innerText(), '我的普通聊天');
    await course(page, '数学');
    const math = await page.evaluate(()=>StudentStore.state.current);
    await rename(page, math, '第二章作业');
    assert.equal(await page.locator('#top-title').innerText(),'第二章作业');
    await page.locator('#top-title').click();await page.locator('#session-name').fill('课程作业改名');
    await page.locator('#save-session-name').click();await page.waitForSelector('#dialog[open]',{state:'hidden'});
    await page.reload();assert.equal(await page.locator('#top-title').innerText(),'课程作业改名');
    await page.locator('#answer-input').fill('草稿保留');
    await deleteCourse(page, '数学', true);
    assert.equal(await page.locator('#answer-input').inputValue(), '草稿保留');
    await course(page, '物理');
    const physics = await page.evaluate(()=>StudentStore.state.current);
    await page.evaluate(()=>{StudentStore.state.resources.push({name:'数学资料.pdf',course:'数学'},{name:'物理资料.pdf',course:'物理'});StudentStore.persist()});
    await deleteCourse(page, '数学');
    assert.equal(await page.evaluate(()=>StudentStore.state.sessions.some(s=>s.course==='数学')),false);
    assert.equal(await page.evaluate(()=>StudentStore.state.resources.some(f=>f.course==='数学')),false);
    assert.equal(await page.evaluate(()=>StudentStore.state.resources.some(f=>f.course==='物理')),true);
    assert.equal(await page.evaluate(()=>StudentStore.state.current),physics);
    await page.reload();
    assert.deepEqual(await page.evaluate(()=>StudentStore.state.courses),['物理']);
    await deleteCourse(page, '物理');
    assert.equal(await page.evaluate(()=>StudentStore.state.current),1);
    assert.equal(await page.locator('#top-title').innerText(),'我的普通聊天');
    assert.deepEqual(await page.evaluate(()=>StudentStore.state.courses),[]);
    await page.evaluate(()=>{for(let i=0;i<10;i++)StudentStore.create('')});
    await page.locator('[data-action="sessions"]').click();
    await page.locator('#popover-root [data-action="session-menu"][data-session="1"]').click();
    await page.locator('#popover-root [data-action="rename-session"]').click();
    await page.locator('#session-name').fill('旧聊天也能改名');await page.locator('#save-session-name').click();
    await page.waitForSelector('#dialog[open]',{state:'hidden'});
    assert.equal(await page.evaluate(()=>StudentStore.state.sessions.find(s=>s.id===1).title),'旧聊天也能改名');
    const legacy = await page.evaluate(()=>{const value=structuredClone(StudentStore.state);value.courses=['概率论与数理统计','高等数学','线性代数'];value.sessions=[{id:1,title:'旧版作业',course:value.courses[0],messages:[],draft:'旧草稿'}];value.current=1;value.course=value.courses[0];value.resources=[];return value});
    await page.evaluate(value=>StudentStore.importState(value),legacy);await page.reload();
    assert.equal(await page.locator('#answer-input').inputValue(),'旧草稿');
    for(const name of legacy.courses)await deleteCourse(page,name);
    assert.deepEqual(await page.evaluate(()=>StudentStore.state.courses),[]);
    assert.equal(await page.evaluate(()=>StudentStore.current().course),'');
    await page.reload();
    assert.deepEqual(await page.evaluate(()=>StudentStore.state.courses),[]);
    assert.deepEqual(errors,[]);
    console.log('PASS: empty first launch, create courses, rename before sending, rename old sessions, delete/cancel courses, scoped deletion, legacy courses, persistence.');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1});
