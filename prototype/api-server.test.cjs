'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { createServer } = require('./api-server.cjs');

const validFrame = { intent: 'local', prerequisite: '', prerequisite_ready: true, action: 'meaning', focus: '当前目标', blocks: ['第一短段。', '第二短段。'], hidden_thought: 'PRIVATE_FRAME' };
const successResponse = () => ({ ok: true, status: 200, async json() { return { model: 'deepseek-flash', choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(validFrame), reasoning_content: 'PRIVATE_REASONING' } }] }; } });

async function startServer(t, fetchImpl, apiKey = 'SECRET_TEST_KEY') {
  const server = createServer({ apiKey, fetchImpl });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  return 'http://127.0.0.1:' + server.address().port;
}
function post(url, data, headers = {}) {
  return fetch(url + '/api/chat', { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(data) });
}

test('HTTP chat returns only decoded text and preserves image attachment content', async t => {
  const calls = [];
  const url = await startServer(t, async (endpoint, options) => { calls.push(JSON.parse(options.body)); return successResponse(); });
  const messages = [{ role: 'user', content: [
    { type: 'text', text: '新题目在图片里。' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,iVBORw0KGgo=' } },
  ] }];
  const response = await post(url, { messages });
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.deepEqual(result, { reply: '第一短段。\n\n第二短段。', model: 'deepseek-flash' });
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE|focus|intent|blocks|SECRET/);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].messages.slice(1), messages);
});

test('HTTP chat recovers an invalid frame once without dropping the latest new question', async t => {
  const calls = [];
  const url = await startServer(t, async (endpoint, options) => {
    calls.push(JSON.parse(options.body));
    if (calls.length === 1) return { ok: true, status: 200, async json() { return { choices: [{ finish_reason: 'stop', message: { content: ' ' } }] }; } };
    return successResponse();
  });
  const messages = [{ role: 'user', content: '改做x+y=1，2x-y=-4。让我自己写。' }];
  const response = await post(url, { messages });
  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  for (const call of calls) assert.deepEqual(call.messages.slice(1), messages);
  assert.deepEqual(await response.json(), { reply: '第一短段。\n\n第二短段。', model: 'deepseek-flash' });
});

test('HTTP chat keeps upstream errors short and never exposes body or key', async t => {
  let calls = 0;
  const url = await startServer(t, async () => { calls++; return { ok: false, status: 401, async json() { return { error: 'PRIVATE_UPSTREAM_TRACE' }; } }; });
  const response = await post(url, { messages: [{ role: 'user', content: '教我这一题。' }] });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: '教学服务密钥无效' });
  assert.equal(calls, 1);
});

test('HTTP chat stops after two invalid frames with the existing generic user error', async t => {
  let calls = 0;
  const url = await startServer(t, async () => { calls++; return { ok: true, status: 200, async json() { return { choices: [{ message: { content: 'PRIVATE_INVALID_FRAME' }, finish_reason: 'stop' }] }; } }; });
  const response = await post(url, { messages: [{ role: 'user', content: '换一道题。' }] });
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: '请求未完成，请重试' });
  assert.equal(calls, 2);
});

test('invalid payload and cross-site requests are rejected before calling the model', async t => {
  let calls = 0;
  const url = await startServer(t, async () => { calls++; return successResponse(); });
  const invalid = await post(url, { messages: [{ role: 'system', content: 'BAD' }] });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: '对话或图片格式不正确' });
  const crossSite = await post(url, { messages: [{ role: 'user', content: '教我。' }] }, { Origin: 'https://other.example' });
  assert.equal(crossSite.status, 403);
  assert.deepEqual(await crossSite.json(), { error: '跨站请求已拒绝' });
  assert.equal(calls, 0);
});

test('health and missing-key errors retain existing behavior without model requests', async t => {
  let calls = 0;
  const url = await startServer(t, async () => { calls++; return successResponse(); }, '');
  const health = await fetch(url + '/api/health');
  assert.deepEqual(await health.json(), { ready: false });
  const response = await post(url, { messages: [{ role: 'user', content: '教我。' }] });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: '未读取到教学服务密钥' });
  assert.equal(calls, 0);
});
