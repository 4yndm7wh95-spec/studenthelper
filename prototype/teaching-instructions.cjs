const fs = require('node:fs'), path = require('node:path');
const base = fs.readFileSync(path.join(__dirname, 'teaching-prompt.txt'), 'utf8').trim();
const opening = fs.readFileSync(path.join(__dirname, 'teaching-opening.txt'), 'utf8').trim();
const contract = fs.readFileSync(path.join(__dirname, 'teaching-contract.txt'), 'utf8').trim();
const requestOptions = Object.freeze(JSON.parse(fs.readFileSync(path.join(__dirname, 'teaching-options.json'), 'utf8')));
const retryInstruction = '上次没有返回可显示的有效回复。重新回答当前学生问题，只输出规定的JSON对象，字段完整。普通回复只讲当前焦点，blocks最多4个短段，不追加下一步；必要原因仍须完整。明确完整答案请求才使用complete。';
const outputInstruction = '最终只返回合法JSON对象，教学正文逐段放在blocks中，不输出JSON之外的文字。';
function instructions(messages) {
  return messages.some(message => message.role === 'assistant') ? base : base + '\n\n' + opening;
}
function wireInstructions(messages, retry = false) { return contract + '\n\n' + instructions(messages) + '\n\n' + outputInstruction + (retry ? '\n\n' + retryInstruction : ''); }
function decodeReply(content) {
  const frame = JSON.parse(content);
  const actions = ['name', 'meaning', 'reason', 'check', 'step', 'complete'];
  const intents = ['opening', 'local', 'continue', 'attempt', 'full'];
  if (!frame || !actions.includes(frame.action) || !intents.includes(frame.intent) ||
      typeof frame.focus !== 'string' || !frame.focus.trim() || frame.focus.length > 120 ||
      typeof frame.prerequisite !== 'string' || typeof frame.prerequisite_ready !== 'boolean' ||
      !Array.isArray(frame.blocks) || !frame.blocks.length || frame.blocks.length > 64 ||
      frame.blocks.some(block => typeof block !== 'string' || !block.trim())) throw Error('Invalid teaching frame');
  if ((frame.action === 'complete') !== (frame.intent === 'full')) throw Error('Invalid teaching action');
  if (!frame.prerequisite_ready && !frame.prerequisite.trim()) throw Error('Missing teaching prerequisite');
  const blocks = frame.blocks.map(block => block.trim());
  const text = blocks.join('\n\n');
  const han = value => (value.match(/[\u3400-\u9fff]/g) || []).length;
  if (frame.action !== 'complete' && (blocks.length > 4 || han(text) > 120 || blocks.some(block => han(block) > 60))) throw Error('Teaching reply exceeded its scope');
  return { frame, text };
}
module.exports = {base, opening, contract, requestOptions, retryInstruction, outputInstruction, instructions, wireInstructions, decodeReply};
