/* Product state and services. Visuals live in workspace.js / workspace.css. */
(()=>{
 const key='yibu-prototype-v1';
 const question='设 0 < P(A) < 1，0 < P(B) < 1，且 P(A | B) + P(A̅ | B̅) = 1，证明 A 与 B 独立。';
 const seed={courses:['概率论与数理统计','高等数学','线性代数'],course:'概率论与数理统计',sessions:[{id:1,title:'第二章作业 · 条件概率',course:'概率论与数理统计',stage:0,messages:[{role:'user',text:'先做第 24 题。'},{role:'paper',text:question},{role:'teacher',html:'先看目标：B 是否发生，不影响 A 的概率。<div class="formula">P(A | B) = P(A)</div>这句话能理解吗？'}],done:false}],current:1,resources:[]};
 let state;try{state=JSON.parse(localStorage.getItem(key))||structuredClone(seed)}catch{state=structuredClone(seed)}
 if(!Array.isArray(state.courses)||!Array.isArray(state.sessions)||!Array.isArray(state.resources))state=structuredClone(seed);
 state.sessions.forEach(s=>{s.messages=Array.isArray(s.messages)?s.messages:[]});
 if(!state.sessions.length)state.sessions=structuredClone(seed.sessions);
 if(!state.sessions.some(s=>s.id===state.current))state.current=state.sessions[0].id;
 const pending=new Set();const requests=new Map();
 const notify=(type='state')=>window.dispatchEvent(new CustomEvent('student:change',{detail:type}));
 const persist=(type)=>{try{localStorage.setItem(key,JSON.stringify(state))}catch{notify('storage-error')}if(type)notify(type)};
 const current=()=>state.sessions.find(s=>s.id===state.current);
 function create(course=state.course){const s={id:Date.now(),title:'新对话',course,stage:0,messages:[],done:false,draft:''};while(state.sessions.some(x=>x.id===s.id))s.id++;state.sessions.unshift(s);state.current=s.id;state.course=course;persist('navigate');return s}
 function select(id){const item=state.sessions.find(s=>s.id===id);if(!item)return;state.current=id;state.course=item.course||'';persist('navigate')}
 function addCourse(name){name=name.trim();if(!name)return false;if(!state.courses.includes(name))state.courses.push(name);state.course=name;persist('courses');return true}
 function plain(html){const element=document.createElement('template');element.innerHTML=html||'';element.content.querySelectorAll('script,style,iframe,object').forEach(n=>n.remove());element.content.querySelectorAll('br').forEach(br=>br.replaceWith('\n'));return element.content.textContent||''}
 async function reply(s){
  if(pending.has(s.id))return;
  pending.add(s.id);s.failure=null;notify('messages');
  const controller=new AbortController();requests.set(s.id,controller);const timeout=setTimeout(()=>controller.abort(),95000);
  try{
   const all=s.messages.filter(m=>['user','teacher','paper'].includes(m.role));const recent=all.slice(-80);const paper=all.findLast(m=>m.role==='paper');if(paper&&!recent.includes(paper))recent.unshift(paper);const messages=recent.map(m=>({role:m.role==='teacher'?'assistant':'user',content:m.text||plain(m.html)}));
   const response=await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages}),signal:controller.signal});
   const data=await response.json();if(!response.ok)throw Error(data.error||'暂时无法回复，请重试');if(typeof data.reply!=='string'||!data.reply.trim())throw Error('没有收到回复，请重试');
   s.messages.push({role:'teacher',text:data.reply});s.failure=null;
  }catch(error){s.failure=error.name==='AbortError'?'回复超时，请重试':error.message||'连接失败，请重试'}
  finally{clearTimeout(timeout);requests.delete(s.id);pending.delete(s.id);persist('messages')}
 }
 async function send(text){text=text.trim();const s=current();if(!text||pending.has(s.id))return;s.draft='';if(!s.messages.length)s.title=text.slice(0,22);s.messages.push({role:s.waitingQuestion?'paper':'user',text});s.waitingQuestion=false;s.live=true;persist('messages');await reply(s)}
 function draft(text){current().draft=text;persist()}
 function resources(files,course=state.course){files.forEach(file=>state.resources.push({name:file.name,course}));persist('resources')}
 function attach(files){current().messages.push({role:'user',text:'附件：'+files.map(file=>file.name).join('、')});persist('messages')}
 function sample(){const s=create('概率论与数理统计');s.title='第二章作业 · 条件概率';s.messages=structuredClone(seed.sessions[0].messages);persist('messages');return s}
 function record(){return state.sessions.find(s=>s.course===state.course&&s.messages.some(m=>m.role==='paper'&&m.text===question))}
 function nextQuestion(){const s=current();if(pending.has(s.id))return;const numbers=s.messages.filter(m=>m.role==='divider').map(m=>Number(m.text.match(/第\s*(\d+)\s*题/)?.[1]||0));const n=Math.max(s.messages.some(m=>m.text===question)?24:1,...numbers)+1;s.messages.push({role:'divider',text:'第 '+n+' 题'});s.waitingQuestion=true;persist('messages')}
 function review(s,status){s.reviewStatus=status;persist('review')}
 function importState(value){if(!value||!Array.isArray(value.courses)||!value.courses.every(c=>typeof c==='string')||!Array.isArray(value.sessions)||!value.sessions.length||!Array.isArray(value.resources)||!value.sessions.every(s=>typeof s.title==='string'&&typeof s.course==='string'&&Array.isArray(s.messages)&&s.messages.every(m=>typeof m.role==='string'&&(typeof m.text==='string'||typeof m.html==='string')))||!value.resources.every(r=>typeof r.name==='string'&&typeof r.course==='string'))throw Error('文件格式不正确');state.courses=value.courses;state.sessions=value.sessions;state.resources=value.resources;state.course=value.course||'';state.current=value.sessions.some(s=>s.id===value.current)?value.current:value.sessions[0].id;state.courseColors=value.courseColors||{};persist('import')}
 persist();
 window.StudentStore={state,current,create,select,addCourse,send,retry:()=>reply(current()),draft,resources,attach,sample,record,question,plain,pending,persist,nextQuestion,review,importState};
})();
