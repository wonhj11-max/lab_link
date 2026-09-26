import { load } from 'cheerio';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createClient } from '@supabase/supabase-js';
import { crawl, safeFetch, readLimited } from './core.mjs';

// This adapter is grounded in ESCML's observed .info/.tit/.opt publication markup.
// It saves a bibliographic index; public approval remains a separate evidence step.
const root='work/official-publications/hanyang-escml';
await mkdir(root,{recursive:true});
const contact=process.env.CRAWLER_CONTACT || 'https://github.com/wonhj11-max/lab_link';
const output=[];
const db=process.argv.includes('--stage') ? createClient(process.env.SUPABASE_URL,process.env.SUPABASE_SECRET_KEY,{auth:{persistSession:false,autoRefreshToken:false}}) : null;
const normalize=s=>s.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]/gu,'');
async function crossref(url){
  for(let attempt=0;attempt<3;attempt++){
    const r=await fetch(url,{headers:{'User-Agent':`LabLinkBibliography/1.0 (${contact})`},signal:AbortSignal.timeout(25000)});
    if(r.ok)return (await r.json()).message;
    if(r.status!==429&&r.status<500)throw Error(`Crossref ${r.status}`);
    await new Promise(resolve=>setTimeout(resolve,1000*2**attempt));
  }
  throw Error('Crossref retry limit');
}
for(const year of [2022,2023,2024,2025,2026]){
  const url=`http://escml.hanyang.ac.kr/sub/sub04_01.php?year=${year}`;
  let html='';
  await crawl({url,allowed_host:'escml.hanyang.ac.kr',allow_http:true},contact,async(...args)=>{
    const r=await safeFetch(...args);
    if(args[0]===url&&r.ok)html=await readLimited(r.clone());
    return r;
  });
  const $=load(html);const entries=[];
  $('a').each((i,a)=>{
    const title=$(a).find('.info .tit').text().trim();
    const citation=$(a).find('.info .opt').text().trim();
    const href=$(a).attr('href')?.trim();
    if(!title||!citation||!href||!/^https?:\/\//.test(href))return;
    entries.push({listing_year:year,title,journal_citation:citation,source_url:url,publisher_source_url:href,doi:href.match(/10\.\d{4,9}\/[^?#\s]+/i)?.[0]?.toLowerCase()||null,authors:[],metadata_status:'pending'});
  });
  if(!entries.length)throw Error(`${year}: markup changed or empty official page`);
  for(const entry of entries){
    try{
      const cacheFile=`${root}/${createHash('sha256').update(entry.publisher_source_url).digest('hex')}.json`;
      let cached;try{cached=JSON.parse(await readFile(cacheFile,'utf8'))}catch{}
      if(cached?.metadata_status==='matched'&&cached.title===entry.title)Object.assign(entry,cached);
      else{
        let record;
        if(entry.doi)record=await crossref(`https://api.crossref.org/works/${encodeURIComponent(entry.doi)}`);
        else{
          const matches=(await crossref(`https://api.crossref.org/works?query.title=${encodeURIComponent(entry.title)}&rows=3`)).items.filter(x=>normalize(x.title?.[0]||'')===normalize(entry.title));
          if(matches.length!==1)throw Error('No unique exact title match');
          record=matches[0];
        }
        if(normalize(record.title?.[0]||'')!==normalize(entry.title))throw Error('Publisher title differs; needs review');
        entry.authors=(record.author||[]).map((a,i)=>({name:[a.given,a.family].filter(Boolean).join(' ')||a.name,order:i+1,affiliations:(a.affiliation||[]).map(x=>x.name)}));
        if(!entry.authors.length)throw Error('No ordered authors');
        entry.doi=record.DOI.toLowerCase();entry.journal=record['container-title']?.[0]||null;
        entry.issn=record.ISSN||[];entry.work_type=record.type;
        entry.publication_date=record['published-print']?.['date-parts']?.[0]||record.published?.['date-parts']?.[0]||null;
        entry.online_publication_date=record['published-online']?.['date-parts']?.[0]||null;
        entry.metadata_source=`https://api.crossref.org/works/${encodeURIComponent(entry.doi)}`;
        entry.metadata_status='matched';entry.checked_at=new Date().toISOString();
      }
      await writeFile(cacheFile,JSON.stringify(entry,null,2));
    }catch(e){entry.metadata_status='held';entry.note=e.message;}
    output.push(entry);
    await writeFile(`${root}/checkpoint.json`,JSON.stringify({updated_at:new Date().toISOString(),processed:output.length,matched:output.filter(x=>x.metadata_status==='matched').length,last_url:entry.publisher_source_url},null,2));
    if(db){const{error}=await db.rpc('stage_official_publication_entries',{p_lab_slug:'hanyang-escml',p_entries:[entry]});if(error)throw Error(error.message);}
    console.log(JSON.stringify({year,doi:entry.doi,status:entry.metadata_status,n:output.length}));
    await new Promise(resolve=>setTimeout(resolve,250));
  }
}
await writeFile(`${root}/index.json`,JSON.stringify(output,null,2));
console.log(JSON.stringify({total:output.length,matched:output.filter(x=>x.metadata_status==='matched').length,held:output.filter(x=>x.metadata_status==='held').length}));
