const fs = require('node:fs'), path = require('node:path');
let sharp; try { sharp = require('sharp'); } catch { sharp = require('C:/Users/kkk/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp'); }
const root = path.join(__dirname,'StudentHelper/Assets.xcassets');
const folder = path.join(root,'AppIcon.appiconset');
fs.mkdirSync(folder,{recursive:true});
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="#F6F4EF"/><path d="M230 522H698" stroke="#1F1E1B" stroke-width="76" stroke-linecap="round"/><path d="M756 522H794" stroke="#D97757" stroke-width="76" stroke-linecap="round"/></svg>';
fs.writeFileSync(path.join(root,'Contents.json'),JSON.stringify({info:{author:'xcode',version:1}}));
fs.writeFileSync(path.join(folder,'Contents.json'),JSON.stringify({images:[{filename:'AppIcon.png',idiom:'universal',platform:'ios',size:'1024x1024'}],info:{author:'xcode',version:1}},null,2));
sharp(Buffer.from(svg)).png().toFile(path.join(folder,'AppIcon.png')).then(()=>console.log('AppIcon created')).catch(()=>{console.error('AppIcon generation failed');process.exitCode=1});
