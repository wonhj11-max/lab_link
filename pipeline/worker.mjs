import { createClient } from '@supabase/supabase-js';
import { mkdir,writeFile,readFile } from 'node:fs/promises';
import { crawl } from './core.mjs';
const dry=process.argv.includes('--dry-run');
const contact=process.env.CRAWLER_CONTACT;
if(!contact)throw Error('Set CRAWLER_CONTACT to an operator contact URL or mailto address.');
if(dry){
 const sources=JSON.parse(await readFile(new URL('./pilot-sources.json',import.meta.url),'utf8'));
 const results=[];
 for(const source of sources.filter(s=>s.enabled)){
  try{const result=await crawl(source,contact);results.push({source:source.url,status:'ok',...result});console.log(JSON.stringify({source:source.url,status:'ok',characters:result.text?.length,doi_candidates:result.candidate?.doi_candidates.length}));}
  catch(e){results.push({source:source.url,status:'failed',error:e.message});console.log(JSON.stringify({source:source.url,status:'failed',error:e.message}));}
  await new Promise(r=>setTimeout(r,2000));
 }
 await mkdir('work',{recursive:true});await writeFile('work/crawl-report.json',JSON.stringify(results,null,2));
}else{
 if(!process.env.SUPABASE_URL||!process.env.SUPABASE_SECRET_KEY)throw Error('Server-only Supabase configuration is missing.');
 const db=createClient(process.env.SUPABASE_URL,process.env.SUPABASE_SECRET_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
 async function rpc(name,args){const{data,error}=await db.rpc(name,args);if(error)throw Error(`${name}: ${error.message}`);return data;}
 await rpc('enqueue_crawl_jobs');
 let failed=0;
 for(let i=0;i<20;i++){
  const job=await rpc('claim_crawl_job');if(!job)break;
  let result;try{result=await crawl(job.source,contact)}catch(e){failed++;result={error:e.message}}
  await rpc('finish_crawl_job',{p_job_id:job.job_id,p_lease_token:job.lease_token,p_result:result});
  console.log(JSON.stringify({job_id:job.job_id,status:result.error?'retry_or_dead':'done'}));
  await new Promise(r=>setTimeout(r,2000));
 }
 if(failed)process.exitCode=1;
}
