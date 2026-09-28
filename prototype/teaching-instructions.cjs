const fs = require('node:fs'), path = require('node:path');
const base = fs.readFileSync(path.join(__dirname, 'teaching-prompt.txt'), 'utf8').trim();
const opening = fs.readFileSync(path.join(__dirname, 'teaching-opening.txt'), 'utf8').trim();
function instructions(messages) {
  return messages.some(message => message.role === 'assistant') ? base : base + '\n\n' + opening;
}
module.exports = {base, opening, instructions};
