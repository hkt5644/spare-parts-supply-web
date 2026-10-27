-- 2단계: 로그인 · 역할 · 업무 함수 (schema.sql 다음에 실행)
-- 원칙: 로그인하고 역할을 받은 사용자만 조회할 수 있고, 모든 변경은 아래 함수로만 한다.
-- 함수가 역할을 확인하고 재고·청구·조달 수량을 한 번에 맞춰 바꾼다.

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'pending' check (role in ('pending', 'unit', 'bn', 'central', 'proc', 'admin')),
  created_at timestamptz not null default now()
);
alter table profiles enable row level security;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'anon')
$$;

-- 가입하면 '승인 대기' 역할로 프로필 생성
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 조회 정책
create policy "본인 또는 관리자 조회" on profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'admin');

do $$
declare t text;
begin
  foreach t in array array['units', 'parts', 'stock_levels', 'usage_logs', 'requisitions',
                           'requisition_items', 'shipments', 'procurements', 'status_history'] loop
    execute format('create policy "승인된 사용자 조회" on public.%I for select to authenticated
                    using (public.my_role() not in (''pending'', ''anon''))', t);
  end loop;
end $$;

create sequence req_seq;
create sequence shp_seq;
create sequence prc_seq;

-- 내부 도우미
create or replace function public.require_role(variadic allowed text[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare r text := public.my_role();
begin
  if r <> 'admin' and not (r = any(allowed)) then
    raise exception '이 작업을 할 권한이 없습니다 (현재 역할: %)', r;
  end if;
end $$;

create or replace function public.write_log(p_actor text, p_msg text) returns void
language sql security definer set search_path = public as $$
  insert into public.status_history (actor, message) values (p_actor, p_msg)
$$;

create or replace function public.new_shipment(p_req text, p_part text, p_qty int) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := 'SHP-' || lpad(nextval('shp_seq')::text, 3, '0');
begin
  insert into shipments (id, requisition_id, part_id, qty) values (v_id, p_req, p_part, p_qty);
  return v_id;
end $$;

-- 같은 품목의 '요청' 단계 조달은 한 건으로 합친다
create or replace function public.add_procurement(p_part text, p_qty int, p_req text) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  select id into v_id from procurements where part_id = p_part and status = '요청' limit 1 for update;
  if found then
    update procurements set qty = qty + p_qty,
      requisition_refs = case when p_req = any(requisition_refs) then requisition_refs else requisition_refs || p_req end
    where id = v_id;
  else
    v_id := 'PRC-' || lpad(nextval('prc_seq')::text, 3, '0');
    insert into procurements (id, part_id, qty, requisition_refs) values (v_id, p_part, p_qty, array[p_req]);
  end if;
  return v_id;
end $$;

-- 중앙 재고로 미결 청구를 오래된 순서대로 채운다
create or replace function public.allocate_backorders(p_part text) returns int
language plpgsql security definer set search_path = public as $$
declare it record; c int; give int; n int := 0; outs text[] := '{}'; pname text; punit text;
begin
  select name, unit into pname, punit from parts where id = p_part;
  for it in
    select i.id, i.backorder, i.requisition_id from requisition_items i
    join requisitions r on r.id = i.requisition_id
    where r.status = '처리중' and i.part_id = p_part and i.backorder > 0
    order by r.created_at, i.id
  loop
    select on_hand into c from stock_levels where unit_id = 'CENTRAL' and part_id = p_part for update;
    give := least(coalesce(c, 0), it.backorder);
    exit when give <= 0;
    update stock_levels set on_hand = on_hand - give where unit_id = 'CENTRAL' and part_id = p_part;
    update requisition_items set backorder = backorder - give, issued = issued + give where id = it.id;
    n := n + 1;
    outs := outs || format('%s에 %s%s 출고(%s)', it.requisition_id, give, punit, public.new_shipment(it.requisition_id, p_part, give));
  end loop;
  if n > 0 then
    perform public.write_log('중앙 물류', format('%s 미결 자동 배분: %s', pname, array_to_string(outs, ', ')));
  end if;
  return n;
end $$;

-- 정비부대: 부속 사용 등록 (물류대대 재고에서 불출)
create or replace function public.use_parts(p_equipment text, p_part text, p_qty int, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare s stock_levels; pt parts;
begin
  perform public.require_role('unit');
  if p_qty is null or p_qty <= 0 then raise exception '수량을 1 이상으로 입력하세요.'; end if;
  select * into pt from parts where id = p_part;
  select * into s from stock_levels where unit_id = 'BN' and part_id = p_part for update;
  if not found then raise exception '등록되지 않은 부속입니다.'; end if;
  if p_qty > s.on_hand then
    raise exception '%', format('대대 보유량(%s%s)보다 많이 불출할 수 없습니다. 물류대대에 긴급 청구가 필요합니다.', s.on_hand, pt.unit);
  end if;
  update stock_levels set on_hand = on_hand - p_qty where unit_id = 'BN' and part_id = p_part returning * into s;
  insert into usage_logs (unit_id, equipment, part_id, qty, note) values ('MC1', p_equipment, p_part, p_qty, nullif(p_note, ''));
  perform public.write_log('정비부대', format('%s 정비: %s %s%s 불출%s', split_part(p_equipment, ' (', 1), pt.name, p_qty, pt.unit,
    coalesce(' (' || nullif(p_note, '') || ')', '')));
  return json_build_object('on_hand', s.on_hand, 'need', s.on_hand + s.pending <= s.reorder_point);
end $$;

-- 물류대대: 정수 대비 부족분 자동 청구
create or replace function public.auto_requisition() returns text
language plpgsql security definer set search_path = public as $$
declare v_id text; v_summary text;
begin
  perform public.require_role('bn');
  if not exists (select 1 from stock_levels where unit_id = 'BN'
                 and on_hand + pending <= reorder_point and authorized_qty - (on_hand + pending) > 0) then
    return null;
  end if;
  v_id := 'REQ-' || lpad(nextval('req_seq')::text, 3, '0');
  insert into requisitions (id, from_unit, to_unit, type) values (v_id, 'BN', 'CENTRAL', '자동');
  insert into requisition_items (requisition_id, part_id, qty)
    select v_id, part_id, authorized_qty - (on_hand + pending) from stock_levels
    where unit_id = 'BN' and on_hand + pending <= reorder_point and authorized_qty - (on_hand + pending) > 0
    order by part_id;
  update stock_levels s set pending = s.pending + i.qty from requisition_items i
    where i.requisition_id = v_id and s.unit_id = 'BN' and s.part_id = i.part_id;
  select string_agg(p.name || ' ' || i.qty || p.unit, ', ' order by i.id) into v_summary
    from requisition_items i join parts p on p.id = i.part_id where i.requisition_id = v_id;
  perform public.write_log('물류대대', format('자동 청구 %s 생성: %s', v_id, v_summary));
  return v_id;
end $$;

create or replace function public.confirm_requisition(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_role('bn');
  update requisitions set status = '중앙접수' where id = p_id and status = '확인대기';
  if not found then raise exception '확인 대기 상태의 청구가 아닙니다.'; end if;
  perform public.write_log('물류대대', format('%s 확인 후 중앙 물류로 전송', p_id));
end $$;

create or replace function public.cancel_requisition(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_role('bn');
  update requisitions set status = '취소' where id = p_id and status = '확인대기';
  if not found then raise exception '확인 대기 상태의 청구만 취소할 수 있습니다.'; end if;
  update stock_levels s set pending = greatest(0, s.pending - i.qty) from requisition_items i
    where i.requisition_id = p_id and s.unit_id = 'BN' and s.part_id = i.part_id;
  perform public.write_log('물류대대', format('%s 취소 (청구중 수량 원복)', p_id));
end $$;

-- 중앙 물류: 재고만큼 출고, 부족분은 미결 + 조달요청
create or replace function public.process_requisition(p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare it record; c int; give int; outs text[] := '{}'; n_out int := 0; n_bo int := 0;
begin
  perform public.require_role('central');
  perform 1 from requisitions where id = p_id and status = '중앙접수' for update;
  if not found then raise exception '중앙 접수 상태의 청구가 아닙니다.'; end if;
  for it in
    select i.id, i.part_id, i.qty, p.name, p.unit from requisition_items i
    join parts p on p.id = i.part_id where i.requisition_id = p_id order by i.id
  loop
    select on_hand into c from stock_levels where unit_id = 'CENTRAL' and part_id = it.part_id for update;
    give := least(coalesce(c, 0), it.qty);
    update stock_levels set on_hand = on_hand - give where unit_id = 'CENTRAL' and part_id = it.part_id;
    update requisition_items set issued = give, backorder = it.qty - give where id = it.id;
    if give > 0 then
      n_out := n_out + 1;
      outs := outs || format('%s %s%s 출고(%s)', it.name, give, it.unit, public.new_shipment(p_id, it.part_id, give));
    end if;
    if it.qty - give > 0 then
      n_bo := n_bo + 1;
      outs := outs || format('%s %s%s 미결 → 조달요청 %s', it.name, it.qty - give, it.unit, public.add_procurement(it.part_id, it.qty - give, p_id));
    end if;
  end loop;
  update requisitions set status = '처리중' where id = p_id;
  perform public.write_log('중앙 물류', format('%s 출고 처리: %s', p_id, array_to_string(outs, ', ')));
  return json_build_object('issued', n_out, 'backorder', n_bo);
end $$;

-- 조달: 요청 → 계약진행 → 입고완료 (입고 시 미결 청구 자동 배분)
create or replace function public.advance_procurement(p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare pr procurements; pname text; punit text; n int := 0;
begin
  perform public.require_role('proc');
  select * into pr from procurements where id = p_id for update;
  if not found then raise exception '조달 요청을 찾을 수 없습니다.'; end if;
  select name, unit into pname, punit from parts where id = pr.part_id;
  if pr.status = '요청' then
    update procurements set status = '계약진행' where id = p_id;
    perform public.write_log('조달', format('%s 계약 진행 (%s %s%s)', p_id, pname, pr.qty, punit));
  elsif pr.status = '계약진행' then
    update procurements set status = '입고완료' where id = p_id;
    update stock_levels set on_hand = on_hand + pr.qty where unit_id = 'CENTRAL' and part_id = pr.part_id;
    perform public.write_log('조달', format('%s 납품: 중앙 물류 %s %s%s 입고', p_id, pname, pr.qty, punit));
    n := public.allocate_backorders(pr.part_id);
  else
    raise exception '이미 입고 완료된 조달 요청입니다.';
  end if;
  return json_build_object('status', (select status from procurements where id = p_id),
                           'allocated', n, 'name', pname, 'qty', pr.qty, 'unit', punit);
end $$;

-- 물류대대: 수령 확인
create or replace function public.receive_shipment(p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare sh shipments; s stock_levels; done boolean; pname text; punit text;
begin
  perform public.require_role('bn');
  select * into sh from shipments where id = p_id and status = '수송중' for update;
  if not found then raise exception '수송 중인 출고가 아닙니다.'; end if;
  select name, unit into pname, punit from parts where id = sh.part_id;
  update shipments set status = '수령완료' where id = p_id;
  update stock_levels set on_hand = on_hand + sh.qty, pending = greatest(0, pending - sh.qty)
    where unit_id = 'BN' and part_id = sh.part_id returning * into s;
  update requisition_items set received = received + sh.qty
    where id = (select id from requisition_items where requisition_id = sh.requisition_id and part_id = sh.part_id order by id limit 1);
  select bool_and(received >= qty) into done from requisition_items where requisition_id = sh.requisition_id;
  if done then update requisitions set status = '완료' where id = sh.requisition_id; end if;
  perform public.write_log('물류대대', format('%s 수령 확인: %s %s%s 입고 (%s)', p_id, pname, sh.qty, punit, sh.requisition_id));
  return json_build_object('on_hand', s.on_hand, 'done', done, 'req', sh.requisition_id, 'name', pname, 'qty', sh.qty, 'unit', punit);
end $$;

-- 물류대대: 정수 · 재청구점 변경
create or replace function public.set_stock_level(p_part text, p_auth int, p_rop int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_role('bn');
  if p_auth is null or p_auth < 1 or p_rop is null or p_rop < 0 then
    raise exception '0 이상의 숫자를 입력하세요. 정수는 1 이상이어야 합니다.';
  end if;
  if p_rop >= p_auth then
    raise exception '%', format('재청구점(%s)은 정수(%s)보다 작아야 합니다.', p_rop, p_auth);
  end if;
  update stock_levels set authorized_qty = p_auth, reorder_point = p_rop where unit_id = 'BN' and part_id = p_part;
  perform public.write_log('물류대대', format('%s 정수 %s, 재청구점 %s로 변경', (select name from parts where id = p_part), p_auth, p_rop));
end $$;

-- 관리자: 사용자 역할 지정
create or replace function public.set_user_role(p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception '관리자만 역할을 바꿀 수 있습니다.'; end if;
  if p_role not in ('pending', 'unit', 'bn', 'central', 'proc', 'admin') then raise exception '알 수 없는 역할입니다.'; end if;
  update profiles set role = p_role where id = p_user;
  perform public.write_log('관리자', format('%s 역할을 %s(으)로 변경', (select email from profiles where id = p_user), p_role));
end $$;

-- 시연용 기초 상태 (가상 데이터)
create or replace function public.seed_demo() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from shipments where true;
  delete from requisition_items where true;
  delete from requisitions where true;
  delete from procurements where true;
  delete from usage_logs where true;
  delete from status_history where true;
  update stock_levels s set on_hand = v.on_hand, pending = v.pending, authorized_qty = v.auth, reorder_point = v.rop
  from (values
    ('BN', 'P01', 9, 0, 30, 12), ('BN', 'P02', 10, 0, 24, 10), ('BN', 'P03', 4, 0, 16, 6), ('BN', 'P04', 3, 6, 10, 4),
    ('BN', 'P05', 20, 0, 20, 8), ('BN', 'P06', 11, 0, 18, 6), ('BN', 'P07', 3, 8, 12, 4), ('BN', 'P08', 9, 0, 14, 5),
    ('CENTRAL', 'P01', 40, 0, 0, 0), ('CENTRAL', 'P02', 0, 0, 0, 0), ('CENTRAL', 'P03', 5, 0, 0, 0), ('CENTRAL', 'P04', 12, 0, 0, 0),
    ('CENTRAL', 'P05', 30, 0, 0, 0), ('CENTRAL', 'P06', 25, 0, 0, 0), ('CENTRAL', 'P07', 0, 0, 0, 0), ('CENTRAL', 'P08', 8, 0, 0, 0)
  ) as v(unit_id, part_id, on_hand, pending, auth, rop)
  where s.unit_id = v.unit_id and s.part_id = v.part_id;
  perform setval('req_seq', 1);
  perform setval('shp_seq', 1);
  perform setval('prc_seq', 1);
  insert into usage_logs (unit_id, equipment, part_id, qty, note, created_at) values
    ('MC1', '전술차량 A형 (가상-101)', 'P01', 4, '엔진오일 교환', '2026-10-24 09:12+09'),
    ('MC1', '발전기 10kW (가상-G03)', 'P02', 2, '연료계통 점검', '2026-10-24 15:40+09'),
    ('MC1', '전술차량 B형 (가상-207)', 'P03', 2, '제동장치 정비', '2026-10-25 10:05+09');
  insert into requisitions (id, from_unit, to_unit, type, status, created_at) values
    ('REQ-001', 'BN', 'CENTRAL', '자동', '처리중', '2026-10-23 06:00+09');
  insert into requisition_items (requisition_id, part_id, qty, issued, backorder, received) values
    ('REQ-001', 'P04', 6, 6, 0, 0),
    ('REQ-001', 'P07', 8, 0, 8, 0);
  insert into shipments (id, requisition_id, part_id, qty, status, created_at) values
    ('SHP-001', 'REQ-001', 'P04', 6, '수송중', '2026-10-24 13:30+09');
  insert into procurements (id, part_id, qty, status, requisition_refs, created_at) values
    ('PRC-001', 'P07', 8, '계약진행', array['REQ-001'], '2026-10-24 13:30+09');
  insert into status_history (actor, message, created_at) values
    ('물류대대', '자동 청구 REQ-001 생성: 배터리 12V 100Ah 6EA, 유압 호스 1/2" 8EA', '2026-10-23 06:00+09'),
    ('물류대대', 'REQ-001 확인 후 중앙 물류로 전송', '2026-10-23 08:20+09'),
    ('정비부대', '전술차량 A형 정비: 엔진오일 필터 4EA 불출', '2026-10-24 09:12+09'),
    ('중앙 물류', 'REQ-001 출고 처리: 배터리 6EA 출고(SHP-001), 유압 호스 8EA 미결 → 조달요청 PRC-001', '2026-10-24 13:30+09'),
    ('정비부대', '발전기 10kW 정비: 연료 필터 2EA 불출', '2026-10-24 15:40+09'),
    ('조달', 'PRC-001 계약 진행', '2026-10-24 16:00+09'),
    ('정비부대', '전술차량 B형 정비: 브레이크 패드 2SET 불출', '2026-10-25 10:05+09');
end $$;

create or replace function public.reset_demo() returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() <> 'admin' then raise exception '관리자만 처음 상태로 되돌릴 수 있습니다.'; end if;
  perform public.seed_demo();
end $$;

-- 실행 권한: 화면에서 부르는 함수만 로그인 사용자에게 연다
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.my_role() to authenticated;
grant execute on function public.use_parts(text, text, int, text), public.auto_requisition(),
  public.confirm_requisition(text), public.cancel_requisition(text), public.process_requisition(text),
  public.advance_procurement(text), public.receive_shipment(text), public.set_stock_level(text, int, int),
  public.set_user_role(uuid, text), public.reset_demo() to authenticated;
grant execute on function public.handle_new_user() to supabase_auth_admin;

select public.seed_demo();
