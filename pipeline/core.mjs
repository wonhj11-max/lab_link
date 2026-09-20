import { createHash } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { load } from 'cheerio';
import robotsParser from 'robots-parser';

export const AGENT='LabLinkResearchBot';
export function validateUrl(value, allowedHost, allowHttp=false){
 const u=new URL(value);
 if((u.protocol!=='https:'&&!(allowHttp&&u.protocol==='http:'))||u.hostname!==allowedHost||u.username||u.password||(u.port&&u.port!=='443'&&!(allowHttp&&u.port==='80'))||isIP(u.hostname)||!u.hostname.includes('.'))throw Error('URL outside approved HTTPS host');
 return u;
}
export function isPublicAddress(ip){
 if(isIP(ip)===4){const [a,b]=ip.split('.').map(Number);return !(a===0||a===10||a===127||a>=224||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&b===168)||(a===100&&b>=64&&b<=127)||(a===198&&(b===18||b===19)));}
 // Conservative global-unicast IPv6 only; IPv4-mapped, loopback and local addresses rejected.
 return isIP(ip)===6&&/^[23][0-9a-f]{3}:/i.test(ip)&&!ip.toLowerCase().startsWith('2001:db8:');
}
export async function safeFetch(value,host,options={}){
 validateUrl(value,host,options.allowHttp===true);
 const addresses=await lookup(host,{all:true});
 if(!addresses.length||addresses.some(a=>!isPublicAddress(a.address)))throw Error('Non-public network target');
 // Sources are operator curated. No public URL-submission endpoint is supported.
 // Redirects are intentionally NOT followed; changes require source review.
 const res=await fetch(value,{...options,redirect:'manual',signal:AbortSignal.timeout(25000)});
 if(res.status>=300&&res.status<400&&res.status!==304){await res.body?.cancel();throw Error('Redirect requires source review');}
 return res;
}
export async function readLimited(res,max=2_000_000){
 if(Number(res.headers.get('content-length'))>max){await res.body?.cancel();throw Error('Response too large');}
 const reader=res.body?.getReader();if(!reader)return '';const parts=[];let total=0;
 try{while(true){const {value,done}=await reader.read();if(done)break;total+=value.length;if(total>max)throw Error('Response too large');parts.push(value)}}finally{await reader.cancel();}
 return new TextDecoder().decode(Buffer.concat(parts));
}
export function extract(html,url){
 const $=load(html);$('script,style,noscript,iframe,nav,footer,header,form').remove();
 const root=$('main').length?$('main'):$('body');
 const normalize=s=>s.replace(/\s+/g,' ').trim();
 const text=normalize(root.text()).replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi,'[email omitted]').replace(/(?:\+82[- .]?)?0?\d{2,3}[- .]\d{3,4}[- .]\d{4}/g,'[phone omitted]').slice(0,100000);
 if(text.length<100)throw Error('Insufficient content; browser rendering or site adapter required');
 const links=[];root.find('a[href]').each((_i,e)=>{try{const href=new URL($(e).attr('href'),url);if(href.protocol==='https:')links.push({text:normalize($(e).text()).slice(0,200),url:href.href})}catch{}});
 const dois=[...new Set(links.filter(l=>new URL(l.url).hostname==='doi.org').map(l=>decodeURIComponent(new URL(l.url).pathname.slice(1)).toLowerCase()))];
 const hash=createHash('sha256').update(text+JSON.stringify(links)).digest('hex');
 return{hash,text,candidate:{source_url:url,title:normalize($('title').text()),excerpt:text.slice(0,3000),doi_candidates:dois,links:links.slice(0,150),corresponding_status:'unknown',review_required:true}};
}
export async function crawl(source,contact,request=safeFetch){
 validateUrl(source.url,source.allowed_host,source.allow_http===true);
 const headers={'User-Agent':`${AGENT}/0.1 (+${contact})`};
 const robotsUrl=new URL('/robots.txt',source.url).href;
 const robots=await request(robotsUrl,source.allowed_host,{headers,allowHttp:source.allow_http===true});
 if(robots.status!==404){
  if(!robots.ok)throw Error(`robots.txt unavailable (${robots.status})`);
  const policy=robotsParser(robotsUrl,await readLimited(robots,500_000));
  if(policy.isAllowed(source.url,AGENT)===false)throw Error('robots.txt disallows this page');
  const delay=policy.getCrawlDelay(AGENT)||0;
  if(delay>30)throw Error('Crawl delay above worker budget; dedicated scheduling required');
  await new Promise(r=>setTimeout(r,Math.max(1500,delay*1000)));
 }
 if(source.etag)headers['If-None-Match']=source.etag;
 if(source.last_modified)headers['If-Modified-Since']=source.last_modified;
 const res=await request(source.url,source.allowed_host,{headers,allowHttp:source.allow_http===true});
 if(res.status===304)return{unchanged:true};
 if(!res.ok)throw Error(`HTTP ${res.status}`);
 if(!/text\/html/i.test(res.headers.get('content-type')||'')){await res.body?.cancel();throw Error('HTML adapter required; unsupported content type');}
 const result=extract(await readLimited(res),source.url);
 if(source.expected_tokens?.length&&!source.expected_tokens.some(token=>(result.text+' '+result.candidate.title).toLowerCase().includes(token.toLowerCase())))throw Error('Source identity mismatch; quarantine and review domain ownership');
 return{...result,etag:res.headers.get('etag'),last_modified:res.headers.get('last-modified')};
}
