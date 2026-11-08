begin;

alter table public.cafe_menus
  add column if not exists valid_from date not null default ((now() at time zone 'Asia/Seoul')::date);
alter table public.cafe_menus
  add column if not exists valid_to date not null default date '9999-12-31';

update public.cafe_menus
   set valid_from = (created_at at time zone 'Asia/Seoul')::date
 where valid_from > (created_at at time zone 'Asia/Seoul')::date;

comment on column public.cafe_menus.valid_from is '유효시작일자';
comment on column public.cafe_menus.valid_to   is '유효종료일자';

update public.cafe_menus m
   set name = v.name
  from (values
    ('conpanna',             '에스프레소 꼰빠냐'),
    ('vanillacreamcoldbrew', '바닐라 크림 콜드브루'),
    ('affogato',             '아포가토 (Haagen-Dazs)'),
    ('hd_ethiopia',          '향기로운 순간 (에티오피아 아바야 게이샤)'),
    ('redginseng',           '홍강진저라떼'),
    ('grainlatte',           '인절미라떼'),
    ('peanutlatte',          '피넛라떼'),
    ('steamedmilk',          '스팀밀크'),
    ('gingertea',            '홍강생강차'),
    ('ashotchu',             '아샷추 (아이스티 샷 추가)'),
    ('amangchu',             '아망추 (아이스티 망고 추가)'),
    ('greengrapeade',        '샤인머스캣에이드'),
    ('icecream_vanilla',     '하겐다즈 바닐라'),
    ('icecream_choco',       '하겐다즈 초코'),
    ('haagenmacadamia',      '하겐다즈 마카다미아')
  ) as v(menu_id, name)
 where m.cafe_id = 'gil' and m.menu_id = v.menu_id and m.name is distinct from v.name;

update public.cafe_menus
   set valid_to = date '2026-11-07'
 where cafe_id = 'gil'
   and menu_id in ('vanillabean','chestnutcream','jaduade','strawberryade','mangolatte','haagendaz')
   and valid_to > date '2026-11-07';

insert into public.cafe_menus (cafe_id, menu_id, name, emoji, cat, temps, extras, popular, sort, valid_from, valid_to)
values
  ('gil','cloudamericano',   '클라우드 아메리카노', '☁️','coffee',  '["ICE","HOT"]'::jsonb, '[]'::jsonb,                 false,  0, date '2026-11-08', date '9999-12-31'),
  ('gil','lightvanilla',     '라이트 바닐라라떼',   '🍦','latte',   '["ICE","HOT"]'::jsonb, '["덜달게","샷추가"]'::jsonb, false,  6, date '2026-11-08', date '9999-12-31'),
  ('gil','peanutcafelatte',  '피넛카페라떼',        '🥜','latte',   '["ICE","HOT"]'::jsonb, '["덜달게"]'::jsonb,          false, 11, date '2026-11-08', date '9999-12-31'),
  ('gil','tarobubbletea',    '타로버블티',          '🧋','tealatte','["ICE","HOT"]'::jsonb, '["덜달게"]'::jsonb,          false, 19, date '2026-11-08', date '9999-12-31'),
  ('gil','teapotset',        '티팟 세트',           '🫖','tea',     '["HOT"]'::jsonb,       '[]'::jsonb,                 false, 34, date '2026-11-08', date '9999-12-31'),
  ('gil','haagen_strawberry','하겐다즈 딸기',       '🍓','dessert', '[]'::jsonb,            '[]'::jsonb,                 false, 73, date '2026-11-08', date '9999-12-31'),
  ('gil','haagen_cookies',   '하겐다즈 쿠앤크',     '🍪','dessert', '[]'::jsonb,            '[]'::jsonb,                 false, 73, date '2026-11-08', date '9999-12-31')
on conflict (cafe_id, menu_id) do nothing;

create or replace function public._dashboard_cells(p_cell text, v_from_t text, v_today_t text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]'::jsonb)
  from (
    select
      cl.id        as cell_id,
      cl.name      as name,
      cl.home_cafe as home_cafe,
      jsonb_array_length(cl.members) as member_count,

      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'date', d.dt, 'servings', d.cnt, 'closed', d.closed) order by d.dt), '[]'::jsonb)
        from (
          select s.date as dt,
                 count(*) filter (where s.state in ('open','closed')) as cnt,
                 count(*) filter (where s.state = 'closed')           as closed
          from public.sessions s
          where s.room_id = cl.room_id
            and s.date >= v_from_t and s.date <= v_today_t
          group by s.date
          having count(*) filter (where s.state in ('open','closed')) > 0
        ) d
      ) as days,

      (select count(distinct s.date) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as used_days,
      (select count(*) from public.sessions s
        where s.room_id = cl.room_id and s.date >= v_from_t and s.date <= v_today_t
          and s.state in ('open','closed')) as servings_total,

      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'member_id',    m.id,
                 'name',         m.name,
                 'dates',        att.dates,
                 'serve_dates',  srv.dates,
                 'attend_ct',    att.ct,
                 'serve_ct',     srv.ct,
                 'attend_total', att.total,
                 'menus',        mnu.menus
               ) order by srv.ct desc, att.ct desc, m.name), '[]'::jsonb)
        from (
          select coalesce(e->>'id',   e #>> '{}') as id,
                 coalesce(e->>'name', e #>> '{}') as name
          from jsonb_array_elements(cl.members) e
        ) m
        left join lateral (
          select coalesce(jsonb_agg(distinct x.d order by x.d), '[]'::jsonb) as dates,
                 count(*)                                                    as ct,
                 (select count(*) from public.orders o2
                    where o2.room_id = cl.room_id and o2.member_id = m.id)   as total
          from (select o.date d from public.orders o
                 where o.room_id = cl.room_id and o.member_id = m.id
                   and o.date >= v_from_t and o.date <= v_today_t) x
        ) att on true
        left join lateral (
          select coalesce(jsonb_agg(distinct y.d order by y.d), '[]'::jsonb) as dates,
                 count(*)                                                    as ct
          from (select s.date d from public.sessions s
                 where s.room_id = cl.room_id and s.host_id = m.id
                   and s.state in ('open','closed')
                   and s.date >= v_from_t and s.date <= v_today_t) y
        ) srv on true
        left join lateral (
          select coalesce(jsonb_agg(jsonb_build_object('menu_id', z.mid, 'name', z.nm, 'count', z.ct)
                            order by z.ct desc, z.nm), '[]'::jsonb) as menus
          from (
            select g.mid, g.ct,
                   coalesce(
                     (select cm.name from public.cafe_menus cm
                       where cm.menu_id = g.mid
                       order by (cm.cafe_id = cl.home_cafe) desc, cm.valid_to desc
                       limit 1),
                     g.last_name, g.mid) as nm
            from (
              select coalesce(nullif(o.menu_id,''), nullif(o.menu_name,''), '기타') as mid,
                     count(*) as ct,
                     (array_agg(o.menu_name order by o.date desc, o.updated_at desc)
                        filter (where nullif(o.menu_name,'') is not null))[1] as last_name
              from public.orders o
              where o.room_id = cl.room_id and o.member_id = m.id and o.type = 'drink'
                and o.date >= v_from_t and o.date <= v_today_t
              group by 1
            ) g
          ) z
        ) mnu on true
      ) as members
    from public.cells cl
    where p_cell is null or cl.id = p_cell
  ) c;
$$;
revoke all on function public._dashboard_cells(text,text,text) from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';
