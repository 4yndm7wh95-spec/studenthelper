const http = require('http'), fs = require('fs'), path = require('path');
const port = Number(process.env.STUDENT_PORT) || 4174;
const host = process.env.STUDENT_HOST || '127.0.0.1';
const payload = require('./chat-payload.cjs');
const teaching = require('./teaching-instructions.cjs');
function json(response, status, data) {
  response.writeHead(status, {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});
  response.end(JSON.stringify(data));
}
http.createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname === '/api/health') return json(response, 200, {ready: !!process.env.DEEPSEEK_API_KEY});
  if (url.pathname === '/api/chat') {
    if (request.method !== 'POST') return json(response, 405, {error:'请求方式错误'});
    if (request.headers.origin) {
      let sameOrigin = false;
      try { const origin = new URL(request.headers.origin); sameOrigin = ['http:', 'https:'].includes(origin.protocol) && origin.host === request.headers.host; } catch {}
      if (!sameOrigin) return json(response, 403, {error:'跨站请求已拒绝'});
    }
    if (!process.env.DEEPSEEK_API_KEY) return json(response, 503, {error:'未读取到教学服务密钥'});
    try {
      const chunks=[];let size=0;
      for await (const chunk of request) { size+=chunk.length;if(size>32*1024*1024)return json(response,413,{error:'图片和对话过大'});chunks.push(chunk); }
      let messages;
      try { const data=JSON.parse(Buffer.concat(chunks).toString('utf8'));messages=payload.messages(data.messages); }
      catch(error){return json(response,400,{error:error.message==='图片格式不正确'||error.message==='图片太大'?error.message:'对话或图片格式不正确'});}
      const result = await fetch('https://api.deepseek.com/chat/completions', {
        method:'POST', headers:{Authorization:'Bearer '+process.env.DEEPSEEK_API_KEY,'Content-Type':'application/json'},
        body:JSON.stringify({model:'deepseek-flash',messages:[{role:'system',content:teaching.instructions(messages)},...messages],max_tokens:1400,thinking:{type:'disabled'}}),
        signal:AbortSignal.timeout(90000)
      });
      if (!result.ok) return json(response, 502, {error:result.status===401?'教学服务密钥无效':result.status===402?'教学服务余额不足':result.status===429?'请求频繁，请稍后重试':'暂时无法回复，请重试'});
      const output = await result.json();
      const reply = output.choices?.[0]?.message?.content;
      if (!reply) throw Error();
      return json(response, 200, {reply,model:output.model});
    } catch { return json(response, 502, {error:'请求未完成，请重试'}); }
  }
  const files = {'/':'index.html','/index.html':'index.html','/workspace.css':'workspace.css','/workspace.js':'workspace.js','/store.js':'store.js','/images.js':'images.js','/math-render.js':'math-render.js','/vendor/katex/katex.min.js':'vendor/katex/katex.min.js','/vendor/katex/katex.min.css':'vendor/katex/katex.min.css'};
  for(const font of fs.readdirSync(path.join(__dirname,'vendor/katex/fonts'))) if(font.endsWith('.woff2')) files['/vendor/katex/fonts/'+font]='vendor/katex/fonts/'+font;
  const file = files[url.pathname];
  if (!file) { response.writeHead(404); return response.end(); }
  fs.readFile(path.join(__dirname,file),(error,body)=>{
    if (error) { response.writeHead(404); return response.end(); }
    response.setHeader('Content-Type',file.endsWith('.js')?'text/javascript; charset=utf-8':file.endsWith('.css')?'text/css; charset=utf-8':file.endsWith('.woff2')?'font/woff2':'text/html; charset=utf-8');
    response.setHeader('Cache-Control','no-cache'); response.end(body);
  });
}).listen(port,host,()=>console.log('Ready http://'+host+':'+port));
