'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const teaching = require('./teaching-instructions.cjs');
const { requestTeachingReply, TeachingServiceError } = require('./teaching-client.cjs');

function frame(blocks = ['先看这一步。'], extra = {}) {
  return { intent: 'local', prerequisite: '', prerequisite_ready: true, action: 'meaning', focus: '当前意思', blocks, ...extra };
}
function completion(content, { finishReason = 'stop', model = 'deepseek-flash' } = {}) {
  return {
    ok: true, status: 200,
    async json() {
      return { model, usage: { total_tokens: 10 }, choices: [{ finish_reason: finishReason, message: { content, reasoning_content: 'HIDDEN_REASONING' } }] };
    },
  };
}
function mockFetch(responses) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options, body: JSON.parse(options.body) });
    const next = responses.shift();
    assert.ok(next, 'Unexpected extra model request');
    if (next instanceof Error) throw next;
    return next;
  };
  return { calls, fetchImpl };
}
const messages = [{ role: 'user', content: '这个符号什么意思？' }];

test('only student-facing blocks are returned, with no frame, thoughts or raw JSON', async () => {
  const hidden = frame(['第一短段。', '\\(x+y=5\\)', '第二短段。'], { thought: 'PRIVATE_FRAME_THOUGHT', private_plan: ['PRIVATE_PLAN'] });
  const mock = mockFetch([completion(JSON.stringify(hidden))]);
  const result = await requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  assert.deepEqual(result, { reply: '第一短段。\n\n\\(x+y=5\\)\n\n第二短段。', model: 'deepseek-flash' });
  assert.deepEqual(Object.keys(result).sort(), ['model', 'reply']);
  assert.doesNotMatch(JSON.stringify(result), /HIDDEN_REASONING|PRIVATE_FRAME_THOUGHT|PRIVATE_PLAN|prerequisite|focus/);
  assert.equal(mock.calls.length, 1);
});

test('default requests use shared model/options and canonical wire instructions', async () => {
  const mock = mockFetch([completion(JSON.stringify(frame()))]);
  await requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  const { url, options, body } = mock.calls[0];
  assert.equal(url, 'https://api.deepseek.com/chat/completions');
  assert.equal(options.method, 'POST');
  assert.equal(options.headers.Authorization, 'Bearer test-key');
  const { messages: sentMessages, ...sentOptions } = body;
  assert.deepEqual(sentOptions, teaching.requestOptions);
  assert.deepEqual(sentMessages, [{ role: 'system', content: teaching.wireInstructions(messages) }, ...messages]);
  assert.equal(body.thinking.type, 'enabled');
  assert.equal(body.reasoning_effort, 'low');
  assert.equal(body.max_tokens, 8192);
});

for (const [name, content] of [
  ['blank content', '   \n '],
  ['non-JSON teaching text', '这题要先求x。'],
  ['invalid frame metadata', JSON.stringify(frame(['当前意思。'], { action: 'unknown' }))],
  ['reply outside the allowed local scope', JSON.stringify(frame(['一。', '二。', '三。', '四。', '五。']))],
]) {
  test(name + ' triggers exactly one recovery request with unchanged student history', async () => {
    const history = [
      { role: 'user', content: 'x+y=5，2x-y=1。' },
      { role: 'assistant', content: '先看第一式。' },
      { role: 'user', content: '换一题x+y=1，2x-y=-4。先让我自己写。' },
    ];
    const snapshot = structuredClone(history);
    const mock = mockFetch([completion(content), completion(JSON.stringify(frame(['好，你先写。'])))]);
    const result = await requestTeachingReply(history, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
    assert.equal(result.reply, '好，你先写。');
    assert.equal(mock.calls.length, 2);
    for (const call of mock.calls) assert.deepEqual(call.body.messages.slice(1), snapshot);
    assert.equal(mock.calls[0].body.messages[0].content, teaching.wireInstructions(snapshot));
    assert.equal(mock.calls[1].body.messages[0].content, teaching.wireInstructions(snapshot, true));
    assert.deepEqual(history, snapshot);
  });
}

test('two invalid replies fail safely and preserve the caller history for its next request', async () => {
  const history = [{ role: 'user', content: '现在换题：x+y=1，2x-y=-4。' }];
  const snapshot = structuredClone(history);
  const mock = mockFetch([
    completion('PRIVATE_INVALID_REPLY'), completion('PRIVATE_INVALID_RETRY'),
    completion(JSON.stringify(frame(['先看这道新题。']))),
  ]);
  await assert.rejects(requestTeachingReply(history, { apiKey: 'SECRET_TEST_KEY', fetchImpl: mock.fetchImpl }), error => {
    assert.ok(error instanceof TeachingServiceError);
    assert.equal(error.message, '请求未完成，请重试');
    assert.doesNotMatch(error.message, /PRIVATE|SECRET|JSON|stack/);
    return true;
  });
  assert.equal(mock.calls.length, 2);
  assert.deepEqual(history, snapshot);
  const nextResult = await requestTeachingReply(history, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  assert.equal(nextResult.reply, '先看这道新题。');
  assert.deepEqual(mock.calls[2].body.messages.slice(1), snapshot);
});

test('length-truncated content is never displayed even if it is valid JSON', async () => {
  const mock = mockFetch([
    completion(JSON.stringify(frame(['TRUNCATED_REPLY'])), { finishReason: 'length' }),
    completion(JSON.stringify(frame(['完整短段。']))),
  ]);
  const result = await requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  assert.equal(result.reply, '完整短段。');
  assert.equal(mock.calls.length, 2);
});

test('two length-truncated replies stop after one retry', async () => {
  const mock = mockFetch([
    completion(JSON.stringify(frame()), { finishReason: 'length' }),
    completion(JSON.stringify(frame()), { finishReason: 'length' }),
  ]);
  await assert.rejects(requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl }), { message: '请求未完成，请重试' });
  assert.equal(mock.calls.length, 2);
});

test('image and text multipart message content is preserved on recovery', async () => {
  const imageMessages = [{ role: 'user', content: [
    { type: 'text', text: '第七题。' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,iVBORw0KGgo=', detail: 'high' } },
  ] }];
  const snapshot = structuredClone(imageMessages);
  const mock = mockFetch([completion(' '), completion(JSON.stringify(frame(['先看题目目标。'])))]);
  await requestTeachingReply(imageMessages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  for (const call of mock.calls) assert.deepEqual(call.body.messages.slice(1), snapshot);
  assert.deepEqual(imageMessages, snapshot);
});

for (const [status, message] of [
  [401, '教学服务密钥无效'], [402, '教学服务余额不足'],
  [429, '请求频繁，请稍后重试'], [500, '暂时无法回复，请重试'],
]) {
  test('HTTP ' + status + ' fails with one request and the existing short user message', async () => {
    const mock = mockFetch([{ ok: false, status, json() { throw Error('Upstream error body should not be read'); } }]);
    await assert.rejects(requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl }), { message });
    assert.equal(mock.calls.length, 1);
  });
}

test('network failures and unreadable HTTP bodies are not retried', async () => {
  for (const response of [new Error('PRIVATE_NETWORK_TRACE'), { ok: true, status: 200, async json() { throw Error('PRIVATE_TRANSPORT_BODY'); } }]) {
    const mock = mockFetch([response]);
    await assert.rejects(requestTeachingReply(messages, { apiKey: 'test-key', fetchImpl: mock.fetchImpl }), { message: '请求未完成，请重试' });
    assert.equal(mock.calls.length, 1);
  }
});

test('complete answers can contain more than four blocks when the protocol permits them', async () => {
  const blocks = ['先整理。', '再代入。', '做运算。', '写结果。', '最后核验。'];
  const mock = mockFetch([completion(JSON.stringify(frame(blocks, { intent: 'full', action: 'complete' })))]);
  const result = await requestTeachingReply([{ role: 'user', content: '给我完整解答。' }], { apiKey: 'test-key', fetchImpl: mock.fetchImpl });
  assert.equal(result.reply, blocks.join('\n\n'));
  assert.equal(mock.calls.length, 1);
});
