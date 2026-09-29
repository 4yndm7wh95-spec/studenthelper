/* 一步 · math-render.js（替换 web/math-render.js 与 ios/WebMath/math-render.js，两处内容必须逐字一致）
 * 责任划分：
 *   render      —— 单个气泡内的公式/粗体渲染（保持原逻辑）
 *   plan        —— 把模型原文拆成“气泡计划”（角色、文本、等待毫秒），纯函数，可在 Node 里测试
 *   structured  —— 把计划渲染为 HTML（每个气泡一个 .yb-reply-part）
 *   createPacer —— 纯逻辑状态机（无 DOM，依赖注入定时器），可在 Node 里测试
 *   pace        —— DOM 适配器：隐藏后续气泡、显示等待指示、调用 createPacer
 * 原文永远整段存储/导出/发给模型；这里只影响显示。
 */
(function(root){
 const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const pattern=/\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|\$\$[\s\S]*?\$\$|\$[^$\n]+\$|P\s*\((?:[^()\n]|\([^()\n]*\))*\)(?:[ \t]*(?:[+\-*/=<>≤≥]|\\(?:cdot|times|mid|leq|geq))[ \t]*(?:P\s*\((?:[^()\n]|\([^()\n]*\))*\)|[A-Za-z\d\\.{}_^]+))*/g;
 function normalize(tex){return tex.replace(/([A-Za-z])[\u0305\u0304]/g,'\\bar{$1}').replace(/Ā/g,'\\bar{A}').replace(/B̄/g,'\\bar{B}')}
 function strong(s){return s.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')}
 function render(text,{cards=true}={}){
  text=String(text);let output='',last=0,previousDisplay=false;pattern.lastIndex=0;
  for(const match of text.matchAll(pattern)){
   let between=text.slice(last,match.index);if(previousDisplay)between=between.replace(/^[，,。;；]\s*/,'');output+=strong(esc(between));
   const raw=match[0],delimited=raw.startsWith('\\[')||raw.startsWith('\\(')||raw.startsWith('$$')||raw.startsWith('$');
   const one=raw.startsWith('$')&&!raw.startsWith('$$');
   const tex=normalize(delimited?raw.slice(one?1:2,one?-1:-2):raw);
   const display=cards&&(raw.startsWith('\\[')||raw.startsWith('$$')||(!delimited&&tex.includes('=')));
   let math;try{math=root.katex.renderToString(tex,{displayMode:display,throwOnError:false,strict:'ignore',trust:false,maxExpand:200,maxSize:10})}catch{math=esc(tex)}
   output+=(display?'<div class="yb-formula">':'<span class="yb-inline-math">')+math+(display?'</div>':'</span>');last=match.index+raw.length;previousDisplay=display;
  }
  let tail=text.slice(last);if(previousDisplay)tail=tail.replace(/^[，,。;；]\s*/,'');output+=strong(esc(tail));return output;
 }

 /* ───────── 分段常量（全部为“权重”单位：汉字=1，英文字母/数字=0.5，标点/空白=0，行内公式=2，裸公式=3） ───────── */
 const TARGET=25,SOFT=30,HARD=36,PAIR_MAX=44,MIN_PIECE=8;
 const HAN1=/\p{Script=Han}/u,HANG=/\p{Script=Han}/gu;
 const ATOM=new RegExp(pattern.source+'|\\*\\*[^*\\n]+\\*\\*','g');
 const STRONG_END=/[。！？!?；;]/,WEAK_END=/[，、,：:]/,CLOSERS=/[”’」』）)】》"']/;
 const OPENERS=/^(如果|若|假如|假设|要是|因为|由于|既然|虽然|尽管|先|首先|当)/,CLOSING=/^(那么|则|就|所以|因此|因而|故|但是|但|可是|然而|却|再|然后|接着|那)/;

 function tokenize(text){
  const out=[];let last=0;const push=s=>{for(const ch of s)out.push({t:'c',s:ch})};
  for(const m of text.matchAll(ATOM)){
   push(text.slice(last,m.index));const src=m[0];
   const kind=src.startsWith('**')?'bold':/^(\\\[|\$\$)/.test(src)?'display':/^(\\\(|\$)/.test(src)?'inline':'bare';
   out.push({t:'a',s:src,kind});last=m.index+src.length;
  }
  push(text.slice(last));return out;
 }
 function plainWeight(s){let w=0;for(const ch of s){if(HAN1.test(ch))w+=1;else if(/[A-Za-z0-9]/.test(ch))w+=.5}return w}
 function tw(k){if(k.t==='a')return k.kind==='bold'?plainWeight(k.s.slice(2,-2)):k.kind==='inline'?2:3;return HAN1.test(k.s)?1:/[A-Za-z0-9]/.test(k.s)?.5:0}
 const weight=toks=>toks.reduce((a,k)=>a+tw(k),0);
 const src=toks=>toks.map(k=>k.s).join('');
 function trim(toks){let a=0,b=toks.length;while(a<b&&toks[a].t==='c'&&/\s/.test(toks[a].s))a++;while(b>a&&toks[b-1].t==='c'&&/\s/.test(toks[b-1].s))b--;return toks.slice(a,b)}
 function plainText(toks){return toks.map(k=>k.t==='a'?(k.kind==='bold'?k.s.slice(2,-2):'\uFFFC'):k.s).join('')}

 // 在“完整意思”边界切开：cutTest(token,nextToken,prevToken) 为真则在该 token 之后切
 function splitAfter(toks,test){
  const parts=[];let cur=[];
  for(let i=0;i<toks.length;i++){
   cur.push(toks[i]);
   if(toks[i].t==='c'&&test(toks[i],toks[i+1],toks[i-1])){
    while(toks[i+1]&&toks[i+1].t==='c'&&CLOSERS.test(toks[i+1].s)){cur.push(toks[++i])}
    parts.push(cur);cur=[];
   }
  }
  if(cur.length)parts.push(cur);return parts.map(trim).filter(p=>p.length);
 }
 const isDigit=k=>k&&k.t==='c'&&/\d/.test(k.s);
 const sentences=toks=>splitAfter(toks,t=>STRONG_END.test(t.s));
 const clauses=toks=>splitAfter(toks,(t,n,p)=>WEAK_END.test(t.s)&&!(t.s===','&&isDigit(p)&&isDigit(n))&&!(t.s===':'&&isDigit(p)&&isDigit(n)));
 function dropTail(toks){const l=toks[toks.length-1];return l&&l.t==='c'&&/[，、,]/.test(l.s)?trim(toks.slice(0,-1)):toks}

 // 无标点的超长句：只在词边界切（Intl.Segmenter）；没有词典能力时宁可不切，也不硬切一个词
 function cutLong(toks){
  if(typeof Intl==='undefined'||!Intl.Segmenter)return [toks];
  const text=plainText(toks);const seg=new Intl.Segmenter('zh',{granularity:'word'});
  const bounds=new Set();let pos=0;for(const s of seg.segment(text)){pos+=s.segment.length;bounds.add(pos)}
  // text 与 toks 一一对应（每个 token 恰好占 1 个 UTF-16 单元以上：bold 内文可能多字，故按 token 累计）
  let acc=0,w=0,best=-1,bestD=1e9;const total=weight(toks),cum=[];
  for(let i=0;i<toks.length;i++){const len=toks[i].t==='a'&&toks[i].kind==='bold'?toks[i].s.length-4:toks[i].t==='a'?1:toks[i].s.length;acc+=len;w+=tw(toks[i]);cum.push([acc,w])}
  for(let i=0;i<toks.length-1;i++){
   const [a,wl]=cum[i];const inAtom=toks[i].t==='a'&&toks[i].kind==='bold';
   if(!bounds.has(a)||inAtom)continue;if(wl<MIN_PIECE||total-wl<MIN_PIECE)continue;
   const d=Math.abs(wl-TARGET);if(d<bestD){bestD=d;best=i}
  }
  return best<0?[toks]:[toks.slice(0,best+1),...cutLong(toks.slice(best+1))].filter(p=>p.length);
 }

 const CONNECT=/^(所以|因此|因而|故|但是|但|可是|然而|那么|则|这样|也就是说|再|然后|接着|最后|另外|同时|而且|并且|不过|还有|同样)/;
 // 一个超过 HARD 的长句：在子句边界上做最优切分（动态规划）。
 //  · 每块目标权重 TARGET；块权重 ≤ HARD（含成对结构的块可到 PAIR_MAX）
 //  · 优先在“所以/因此/那么/再…”等连接词之前切（罚分 0，否则 60）
 //  · 不拆“如果…那么/因为…所以/先…再”成对结构；碎片（<MIN_PIECE）重罚
 function packClauses(cl){
  const m=cl.length,w=cl.map(weight),txt=cl.map(plainText);
  const P=Array(m+1).fill(false); // P[b]=true：第 b 个子句之前的边界处于“如果…那么/因为…所以/先…再”区间内，不许切
  for(let i=0;i<m;i++){if(!OPENERS.test(txt[i]))continue;let sum=0;
   for(let j=i;j<m;j++){sum+=w[j];if(sum>PAIR_MAX)break;if(j>i&&CLOSING.test(txt[j])){for(let b=i+1;b<=j;b++)P[b]=true;break}}}
  const prot=b=>P[b];
  const pen=j=>j>=m?0:CONNECT.test(txt[j])?0:60;
  const dp=Array(m+1).fill(Infinity),from=Array(m+1).fill(-1);dp[0]=0;
  for(let j=1;j<=m;j++){let W=0;
   for(let i=j-1;i>=0;i--){
    W+=w[i];const multi=j-i>1;if(multi&&W>PAIR_MAX)break;
    if(multi&&W>HARD){let ok=false;for(let k=i+1;k<j;k++)if(prot(k))ok=true;if(!ok)continue}
    if(i>0&&prot(i))continue;
    const cost=dp[i]+(W-TARGET)**2/4+(W<MIN_PIECE?(MIN_PIECE-W)**2*2:0)+pen(j);
    if(cost<dp[j]){dp[j]=cost;from[j]=i}
   }
  }
  if(!isFinite(dp[m]))return [trim(cl.flat())];
  const pieces=[];for(let j=m;j>0;j=from[j])pieces.unshift(cl.slice(from[j],j).flat());
  const out=pieces.map((p,i)=>i<pieces.length-1?dropTail(trim(p)):trim(p));
  return out.flatMap(p=>weight(p)>HARD&&clauses(p).length<2?cutLong(p):[p]);
 }

 function textToBubbles(toks){
  toks=trim(toks);if(!toks.length)return [];
  const sents=sentences(toks);const groups=[];let cur=[],cw=0;
  for(const s of sents){const w=weight(s);
   if(cur.length&&cw+w>SOFT){groups.push(cur.flat());cur=[];cw=0}
   cur.push(s);cw+=w;
  }
  if(cur.length)groups.push(cur.flat());
  const out=[];
  for(const g of groups){
   if(weight(g)<=HARD)out.push(trim(g));
   else out.push(...packClauses(clauses(g)));
  }
  // 极短碎片（<6）并回同一行里的前一个气泡（合并后 ≤ HARD 才合并）
  const merged=[];for(const p of out){const prev=merged[merged.length-1];
   if(prev&&weight(p)<6&&weight(prev)+weight(p)<=HARD&&!/[？?]$/.test(src(p)))merged[merged.length-1]=prev.concat(p);else merged.push(p)}
  return merged.map(p=>({kind:'text',toks:p}));
 }

 function lineToBubbles(line){
  line=trim(line);if(!line.length)return [];
  const out=[];let run=[];
  const flush=()=>{if(run.length){out.push(...textToBubbles(run));run=[]}};
  const core=line.filter(k=>!(k.t==='c'&&/[\s，,。；;、]/.test(k.s)));
  if(core.length===1&&core[0].t==='a'&&core[0].kind!=='bold')return [{kind:'formula',toks:core}];
  for(const k of line){
   if(k.t==='a'&&k.kind==='display'){flush();out.push({kind:'formula',toks:[k]})}else run.push(k);
  }
  flush();return out;
 }

 function toDisplaySrc(k){ // 单独成行的行内/裸公式，统一按独立公式卡渲染
  if(k.kind==='display')return k.s;
  if(k.kind==='inline'){const s=k.s;return s.startsWith('\\(')?'\\['+s.slice(2,-2)+'\\]':'$$'+s.slice(1,-1)+'$$'}
  return '\\['+k.s+'\\]';
 }

 /* ───────── 等待时长：上一个气泡的中文字数 × 500ms；无汉字时按符号数计 ───────── */
 const MATH_ALL=new RegExp(pattern.source,'g');
 function hanCount(s){return (String(s).replace(MATH_ALL,'').match(HANG)||[]).length}
 function symbolCount(s){return Array.from(String(s).replace(/\\[\[\]()]|\$/g,'').replace(/\\[A-Za-z]+/g,'x').replace(/[{}\s]/g,'')).length}
 function delayFor(text){const han=hanCount(text);if(han)return han*500;return Math.min(6000,Math.max(2000,symbolCount(text)*250))}

 // plan：返回 [{role,kind,src,han,ms}]；ms=显示完本气泡后，等多久才显示下一个（最后一个为 0）
 function plan(text){
  text=String(text).replace(/\r\n?/g,'\n').replace(/\*\*([^*\n]*?(?:\\\(|\\\[|\$)[^*\n]*?)\*\*/g,'$1');
  const lines=[];let cur=[];
  for(const k of tokenize(text)){if(k.t==='c'&&k.s==='\n'){lines.push(cur);cur=[]}else cur.push(k)}
  lines.push(cur);
  const bubbles=lines.flatMap(lineToBubbles).map(b=>{
   const s=b.kind==='formula'?toDisplaySrc(b.toks[0]):src(b.toks);
   return {kind:b.kind,role:b.kind==='formula'?'formula':'explain',src:s,han:hanCount(s)};
  });
  const firstText=bubbles.find(b=>b.kind==='text'),last=bubbles[bubbles.length-1];
  if(firstText&&/\*\*/.test(firstText.src))firstText.role='lead';          // 只有模型自己加了粗体，首个文字气泡才是“重点”
  if(last&&last.kind==='text'&&/[？?][”’」』）)"']*$/.test(last.src.trim()))last.role='ask'; // 只有回复最后一个气泡以问号结尾才是“提问”
  bubbles.forEach((b,i)=>{b.ms=i<bubbles.length-1?delayFor(b.src):0});
  return bubbles;
 }
 function blocks(text){return plan(text).map(b=>b.src)}

 function structured(text){
  const parts=plan(text);
  return '<div class="yb-reply-parts" data-count="'+parts.length+'">'+parts.map(b=>
   '<div class="yb-reply-part" data-role="'+b.role+'" data-ms="'+b.ms+'"><div class="yb-reply-wrap"><div class="yb-bubble is-'+b.role+'">'+render(b.src,{cards:b.kind==='formula'})+'</div></div></div>').join('')+'</div>';
 }

 /* ───────── 状态机（纯逻辑）：first_visible → paced_wait ⇄ next_visible → complete ─────────
  * delays[i]：显示第 i 个气泡后，等 delays[i] 毫秒显示第 i+1 个。
  * hooks.reveal(i,mode)：mode = 'rise'（正常出现）| 'fade'（被跳过/提前发送，一次性淡入）
  * hooks.wait(on)：等待指示显示/隐藏（在上一个气泡出现 WAIT_IN 毫秒后才显示，且只有该段等待 ≥ WAIT_MIN 才显示）
  * hooks.done()：全部显示完毕
  */
 const WAIT_IN=420,WAIT_MIN=1000;
 function createPacer(delays,hooks,env={}){
  const setT=env.setTimeout||setTimeout,clearT=env.clearTimeout||clearTimeout,now=env.now||(()=>performance.now());
  const n=delays.length+1;let shown=0,state='network_wait',dueAt=0,remaining=0,timer=null,waitTimer=null,waitOn=false,paused=false,dead=false;
  const setWait=on=>{if(waitOn!==on){waitOn=on;hooks.wait&&hooks.wait(on)}};
  const clear=()=>{clearT(timer);clearT(waitTimer);timer=waitTimer=null};
  function schedule(ms){
   clear();dueAt=now()+ms;remaining=ms;
   if(ms>=WAIT_MIN)waitTimer=setT(()=>{waitTimer=null;if(!dead&&!paused&&state==='paced_wait')setWait(true)},Math.min(WAIT_IN,Math.max(0,ms-600)));
   timer=setT(next,ms);
  }
  function next(){
   if(dead||paused)return;timer=null;setWait(false);state='next_visible';hooks.reveal(shown,'rise');shown++;after();
  }
  function after(){
   if(shown>=n){state='complete';clear();setWait(false);hooks.done&&hooks.done();return}
   state='paced_wait';schedule(delays[shown-1]);
  }
  return {
   start(){if(dead||shown)return;state='first_visible';hooks.reveal(0,'rise');shown=1;after()},
   skip(){if(dead||state==='complete')return;clear();setWait(false);const from=shown;while(shown<n){hooks.reveal(shown,'fade');shown++}state='complete';hooks.done&&hooks.done();return n-from},
   pause(){if(dead||paused||state!=='paced_wait')return;paused=true;remaining=Math.max(0,dueAt-now());clear()},
   resume(){if(dead||!paused)return;paused=false;schedule(remaining)},
   destroy(){dead=true;clear();setWait(false)},
   get state(){return state},get shown(){return shown},get remaining(){return paused?remaining:Math.max(0,dueAt-now())}
  };
 }

 /* ───────── DOM 适配器 ───────── */
 const active=new Set();
 function makeWait(){
  const el=document.createElement('div');el.className='yb-reply-wait';el.dataset.state='enter';el.setAttribute('role','status');el.setAttribute('aria-label','正在准备下一句');
  el.innerHTML='<div class="yb-reply-wrap"><div class="yb-wait-pill"><i></i><i></i><i></i></div></div>';return el;
 }
 // 给一个已渲染的老师回复（.yb-reply-parts）加上节奏。返回控制器；少于 2 个气泡时无事可做。
 // onReveal(info)：每次有气泡/指示改变高度时回调，workspace.js 在这里决定是否跟随滚动。
 function pace(container,{onReveal=()=>{},reduced=false}={}){
  const parts=[...container.querySelectorAll('.yb-reply-part')];
  if(parts.length<2)return {skip(){return 0},finish(){},destroy(){},get state(){return 'complete'}};
  const holder=container.querySelector('.yb-reply-parts');
  parts.slice(1).forEach(p=>p.hidden=true);
  let waitEl=null,ctl=null;
  const clear=(el,ms)=>setTimeout(()=>{if(el.isConnected)delete el.dataset.state},ms);
  const hooks={
   reveal(i,mode){
    const p=parts[i];p.hidden=false;
    if(reduced||mode==='fade'){p.dataset.state='fade';void p.offsetHeight;p.dataset.state='fade-in';clear(p,260)}
    else{p.dataset.state='enter';void p.offsetHeight;p.dataset.state='in';clear(p,460)}
    onReveal({index:i,mode,total:parts.length});
   },
   wait(on){
    if(on&&!waitEl){waitEl=makeWait();holder.append(waitEl);void waitEl.offsetHeight;waitEl.dataset.state=reduced?'static':'in';onReveal({wait:true})}
    else if(!on&&waitEl){const el=waitEl;waitEl=null;if(reduced){el.remove();return}el.dataset.state='out';setTimeout(()=>el.remove(),340)}
   },
   done(){detach();onReveal({done:true})}
  };
  const pacer=createPacer(parts.slice(0,-1).map(p=>Number(p.dataset.ms)||0),hooks);
  const onVis=()=>document.visibilityState==='hidden'?pacer.pause():pacer.resume();
  function detach(){document.removeEventListener('visibilitychange',onVis);active.delete(ctl)}
  ctl={
   skip(){return pacer.skip()},
   finish(){pacer.destroy();parts.forEach(p=>{p.hidden=false;delete p.dataset.state});waitEl?.remove();waitEl=null;detach()},
   destroy(){ctl.finish()},
   get state(){return pacer.state}
  };
  document.addEventListener('visibilitychange',onVis);active.add(ctl);pacer.start();return ctl;
 }
 function finishAll(){[...active].forEach(c=>c.finish())}       // 切会话/切页/删除/重启后重绘：立刻完整显示，不重放
 function skipAll(){let n=0;[...active].forEach(c=>{n+=c.skip()||0});return n}   // 提前发送、点“跳过等待”
 function hasActive(){return active.size>0}
 root.StudentMath={render,normalize,plan,blocks,structured,pace,createPacer,delayFor,hanCount,finishAll,skipAll,hasActive,_const:{TARGET,SOFT,HARD,PAIR_MAX,WAIT_IN,WAIT_MIN}};
})(globalThis);
