(function(root){
 const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const pattern=/\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|\$\$[\s\S]*?\$\$|\$[^$\n]+\$|P\s*\((?:[^()\n]|\([^()\n]*\))*\)(?:[ \t]*(?:[+\-*/=<>≤≥]|\\(?:cdot|times|mid|leq|geq))[ \t]*(?:P\s*\((?:[^()\n]|\([^()\n]*\))*\)|[A-Za-z\d\\.{}_^]+))*/g;
 function normalize(tex){return tex.replace(/([A-Za-z])[\u0305\u0304]/g,'\\bar{$1}').replace(/Ā/g,'\\bar{A}').replace(/B̄/g,'\\bar{B}')}
 function render(text,{cards=true}={}){
  let output='',last=0,previousDisplay=false;pattern.lastIndex=0;
  for(const match of String(text).matchAll(pattern)){
   let between=text.slice(last,match.index);if(previousDisplay)between=between.replace(/^[，,。;；]\s*/,'');output+=esc(between).replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
   const raw=match[0],delimited=raw.startsWith('\\[')||raw.startsWith('\\(')||raw.startsWith('$$')||raw.startsWith('$');
   const tex=normalize(delimited?raw.slice(raw.startsWith('$')&&!raw.startsWith('$$')?1:2,raw.startsWith('$')&&!raw.startsWith('$$')?-1:-2):raw);
   const display=cards&&(raw.startsWith('\\[')||raw.startsWith('$$')||(!delimited&&tex.includes('=')));
   let math;try{math=root.katex.renderToString(tex,{displayMode:display,throwOnError:false,strict:'ignore',trust:false,maxExpand:200,maxSize:10})}catch{math=esc(tex)}
   output+=(display?'<div class="yb-formula">':'<span class="yb-inline-math">')+math+(display?'</div>':'</span>');last=match.index+raw.length;previousDisplay=display;
  }
  let tail=text.slice(last);if(previousDisplay)tail=tail.replace(/^[，,。;；]\s*/,'');output+=esc(tail).replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');return output;
 }
 root.StudentMath={render,normalize};
})(globalThis);
