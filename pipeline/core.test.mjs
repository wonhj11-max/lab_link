import test from 'node:test';
import assert from 'node:assert/strict';
import { validateUrl,isPublicAddress,extract,crawl,readLimited } from './core.mjs';
test('rejects unapproved hosts, credentials, ports and network addresses',()=>{
 for(const url of ['http://lab.snu.ac.kr/','https://lab.snu.ac.kr.evil.com/','https://user@lab.snu.ac.kr/','https://lab.snu.ac.kr:444/','https://127.0.0.1/'])assert.throws(()=>validateUrl(url,'lab.snu.ac.kr'));
 assert.equal(validateUrl('https://lab.snu.ac.kr/research','lab.snu.ac.kr').pathname,'/research');
 for(const ip of ['127.0.0.1','10.1.1.1','169.254.169.254','172.16.0.1','192.168.1.1','::1','::ffff:127.0.0.1','fc00::1','fe80::1'])assert.equal(isPublicAddress(ip),false);
 assert.equal(isPublicAddress('8.8.8.8'),true);
});
const html='<html><title>Research</title><nav>navigation</nav><main><h1>Research</h1><p>'+('Battery materials and electrochemistry. '.repeat(8))+'person@example.com 010-1234-5678</p><a href="https://doi.org/10.1000/ABC">Paper</a></main><script>secret()</script></html>';
test('stable extraction redacts contacts and preserves DOI candidates without inferring authorship',()=>{
 const a=extract(html,'https://lab.snu.ac.kr/');const b=extract(html.replace('navigation','another menu'),'https://lab.snu.ac.kr/');
 assert.equal(a.hash,b.hash);assert.ok(!a.text.includes('person@example.com'));assert.ok(!a.text.includes('010-1234-5678'));assert.ok(!a.text.includes('secret()'));
 assert.deepEqual(a.candidate.doi_candidates,['10.1000/abc']);assert.equal(a.candidate.corresponding_status,'unknown');
 assert.throws(()=>extract('<html>JavaScript app</html>','https://lab.snu.ac.kr/'));
});
test('robots disallow prevents fetching source',async()=>{
 let n=0;await assert.rejects(crawl({url:'https://lab.snu.ac.kr/private',allowed_host:'lab.snu.ac.kr'},'https://example.com',async()=>{n++;return new Response('User-agent: *\nDisallow: /private')}),/disallows/);assert.equal(n,1);
});
test('robots errors fail closed and 304 does not create content',async()=>{
 await assert.rejects(crawl({url:'https://lab.snu.ac.kr/',allowed_host:'lab.snu.ac.kr'},'https://example.com',async()=>new Response('',{status:503})),/unavailable/);
 const r=await crawl({url:'https://lab.snu.ac.kr/',allowed_host:'lab.snu.ac.kr'},'https://example.com',async url=>new Response(null,{status:url.endsWith('robots.txt')?404:304}));assert.deepEqual(r,{unchanged:true});
});
test('oversized responses are rejected',async()=>{await assert.rejects(readLimited(new Response('x'.repeat(50)),10),/too large/)});
