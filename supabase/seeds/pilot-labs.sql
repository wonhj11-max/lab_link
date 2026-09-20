-- Reviewed pilot directory. Sources observed 2026-09-17/18; not a complete publication inventory.
begin;
insert into public.labs(slug,name,university,department,professor,homepage,introduction,topics,publication_state,verified_at) values
('hanyang-escml','에너지저장 및 변환소재 연구실','한양대학교','에너지공학과 · 배터리공학과','선양국','http://escml.hanyang.ac.kr/','리튬이차전지의 양극·음극 소재 합성과 전기화학적 특성을 연구합니다. 전고체전지와 리튬금속전지 등 차세대 전지 소재로 연구를 확장합니다.',array['양극 소재','전고체전지','리튬금속'],'published',now()),
('snu-mest','멀티스케일 에너지 과학 연구실','서울대학교','화학생물공학부','최장욱','https://mest.snu.ac.kr/','이차전지 전극과 바인더, 전해질 및 전지 시스템을 연구합니다. 실리콘 음극, 리튬금속, 전고체전지와 수계 에너지 저장 기술을 다룹니다.',array['실리콘 음극','바인더','전고체전지'],'published',now()),
('snu-aeml','에너지 신소재 연구실','서울대학교','재료공학부','강기석','https://energylab.snu.ac.kr/main/main.html','실험과 제일원리 계산을 결합해 에너지 저장 소재를 설계합니다. 리튬 및 차세대 금속이온 전지, 전고체전지, 유기 전지를 연구합니다.',array['전극 소재','제일원리 계산','전고체전지'],'published',now()),
('unist-cho','이차전지 소재 연구실','UNIST','에너지화학공학과','조재필','https://www.unist.ac.kr/unist/center/resualt.do?mode=list&tag=%EC%A1%B0%EC%9E%AC%ED%95%84','이차전지 전극 소재에 관한 연구를 수행합니다. 현재 대학 공식 연구 자료를 연결했으며, 연구실 독립 홈페이지의 유효한 주소를 재확인하고 있습니다.',array['이차전지','음극 소재'],'published',now()),
('hanyang-aetl','차세대 전기화학 연구실','한양대학교','에너지공학과 · 배터리공학과','김한수','https://battery.hanyang.ac.kr/lab4','전기화학 기반 에너지 저장 소재와 고용량 음극을 연구합니다. 실리콘·주석·전이금속 산화물과 무기 전해액 기반 이차전지 시스템을 다룹니다.',array['고용량 음극','실리콘 복합체','전기화학'],'published',now())
on conflict(slug) do nothing;
insert into public.lab_facts(lab_id,kind,title,body,source_url,observed_at,publication_state)
select l.id,v.kind,v.title,v.body,v.url,now(),'published' from (values
('hanyang-escml','research','전극 소재와 차세대 전지','양극·음극 소재의 합성, 물리적·전기화학적 특성 분석, 전지 성능 평가를 연구합니다.','https://battery.hanyang.ac.kr/lab1'),
('snu-mest','research','소재 설계에서 전지 시스템까지','리튬이온·리튬금속·리튬황 전지, 실리콘 바인더, 유연 전지, 용액 공정 전고체전지, 수계 에너지 저장 및 리튬 회수를 다룹니다.','https://mest.snu.ac.kr/research/'),
('snu-mest','biography','학력과 주요 연구 이력','서울대학교 화학공학 학사(2002), Caltech 박사(2007). Stanford 박사후연구원(2008~2010), KAIST 교원(2010~2017), 서울대학교 교원(2017~).','https://mest.snu.ac.kr/prof-jang-wook-choi/'),
('snu-mest','alumni','홈페이지에 공개된 진로 사례','공개된 박사과정 졸업생 목록에 Samsung SDI, LG Energy Solution, SK On, 대학 교원, 연구기관 등의 진로가 기재되어 있습니다. 일부 공개 사례이며 현재 재직 여부나 전체 졸업생의 취업률을 의미하지 않습니다.','https://mest.snu.ac.kr/alumni/'),
('snu-aeml','research','실험과 계산을 결합한 에너지 소재 설계','전극 소재와 차세대 전기화학 에너지 저장을 연구하며, 제일원리 계산과 합성·분석을 결합합니다.','https://mse.snu.ac.kr/kang-kisuk/'),
('snu-aeml','biography','학력','서울대학교 재료공학 학사(2001), MIT 재료공학 박사(2006).','https://mse.snu.ac.kr/kang-kisuk/'),
('unist-cho','research','공식 대학 연구 자료 연결','UNIST 공식 연구 자료에서 이차전지 전극 소재 연구를 확인할 수 있습니다. 이전 연구실 도메인은 현재 연구실과 무관한 콘텐츠를 표시하므로 연결하지 않습니다.','https://www.unist.ac.kr/unist/center/resualt.do?mode=list&tag=%EC%A1%B0%EC%9E%AC%ED%95%84'),
('hanyang-aetl','research','차세대 고용량 음극','실리콘·주석 및 전이금속 산화물의 리튬 저장, Si/SiOx 및 Si/Carbon 복합체, 무기 전해액 기반 이차전지를 연구합니다.','https://battery.hanyang.ac.kr/lab4')
) as v(slug,kind,title,body,url) join public.labs l on l.slug=v.slug
where not exists(select 1 from public.lab_facts f where f.lab_id=l.id and f.title=v.title);
insert into private.sources(lab_id,url,allowed_host,category,allow_http,expected_tokens,enabled,review_note)
select l.id,v.url,v.host,v.category,v.http,v.tokens,false,'파일럿 수집 결과와 사이트 정책 검토 후 활성화' from (values
('snu-mest','https://mest.snu.ac.kr/prof-jang-wook-choi/','mest.snu.ac.kr','biography',false,array['Jang Wook Choi']),
('snu-mest','https://mest.snu.ac.kr/논문/','mest.snu.ac.kr','publications',false,array['Jang Wook Choi']),
('snu-mest','https://mest.snu.ac.kr/alumni/','mest.snu.ac.kr','alumni',false,array['Mest period']),
('snu-aeml','https://energylab.snu.ac.kr/professor/professor.html','energylab.snu.ac.kr','biography',false,array['Kisuk','강기석']),
('hanyang-escml','http://escml.hanyang.ac.kr/sub/sub01_01.php','escml.hanyang.ac.kr','research',true,array['Energy Storage','Sun','battery']),
('hanyang-aetl','https://battery.hanyang.ac.kr/lab4','battery.hanyang.ac.kr','research',false,array['김한수','Hansu Kim'])
) v(slug,url,host,category,http,tokens) join public.labs l on l.slug=v.slug on conflict(url) do nothing;
commit;
