'use strict';

const teaching = require('./teaching-instructions.cjs');
const ENDPOINT = 'https://api.deepseek.com/chat/completions';
const UNFINISHED = '请求未完成，请重试';

class TeachingServiceError extends Error {
  constructor(message = UNFINISHED) {
    super(message);
    this.name = 'TeachingServiceError';
  }
}

function httpMessage(status) {
  if (status === 401) return '教学服务密钥无效';
  if (status === 402) return '教学服务余额不足';
  if (status === 429) return '请求频繁，请稍后重试';
  return '暂时无法回复，请重试';
}

async function requestTeachingReply(messages, { apiKey, fetchImpl = globalThis.fetch } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    let response;
    try {
      response = await fetchImpl(ENDPOINT, {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...teaching.requestOptions,
          messages: [{ role: 'system', content: teaching.wireInstructions(messages, attempt === 1) }, ...messages],
        }),
        signal: AbortSignal.timeout(90000),
      });
    } catch {
      throw new TeachingServiceError();
    }
    if (!response.ok) throw new TeachingServiceError(httpMessage(response.status));

    let output;
    try { output = await response.json(); }
    catch { throw new TeachingServiceError(); }

    try {
      const choice = output?.choices?.[0];
      if (choice?.finish_reason === 'length') throw Error('Truncated teaching reply');
      const reply = teaching.decodeReply(choice?.message?.content).text;
      return { reply, model: output.model };
    } catch {
      if (attempt === 1) throw new TeachingServiceError();
    }
  }
  throw new TeachingServiceError();
}

module.exports = { requestTeachingReply, TeachingServiceError };
