-- 4단계: 정비부대 관리 기능 (public_mode.sql 다음에 실행)
-- 장비 목록, 부속 품목, 정비부대 자체 재고는 '로그인한' 정비부대 사용자와 관리자만 바꿀 수 있다.
-- 공개 모드여도 로그인하지 않은 사람은 볼 수만 있다.

create table equipment (
  id bigint generated always as identity primary key,
  unit_id text not null default 'MC1' references units(id),
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table equipment enable row level security;
create policy "승인된 사용자 조회" on equipment for select to authenticated
  using (public.my_role() not in ('pending', 'anon'));
create policy "공개 모드 조회" on equipment for select to anon, authenticated
  using (public.public_mode());

insert into equipment (name) values
  ('전술차량 A형 (가상-101)'), ('전술차량 B형 (가상-207)'), ('발전기 10kW (가상-G03)'), ('지게차 3톤 (가상-F12)');

-- 정비부대(MC1) 자체 재고 행
insert into stock_levels (unit_id, part_id, on_hand)
  select 'MC1', id, 0 from parts on conflict (unit_id, part_id) do nothing;
update stock_levels set on_hand = case part_id when 'P01' then 2 when 'P06' then 1 else 0 end where unit_id = 'MC1';

-- 공개 모드와 상관없이 로그인 + 역할을 요구
create or replace function public.require_login_role(variadic allowed text[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare r text := public.my_role();
begin
  if auth.uid() is null then raise exception '로그인한 사용자만 할 수 있습니다. 오른쪽 위 로그인 버튼으로 로그인하세요.'; end if;
  if r <> 'admin' and not (r = any(allowed)) then
    raise exception '이 작업을 할 권한이 없습니다 (현재 역할: %)', r;
  end if;
end $$;

-- 정비 사용: 자체 재고에서 먼저 쓰고, 모자란 만큼 물류대대에서 불출
create or replace function public.use_parts(p_equipment text, p_part text, p_qty int, p_note text default null) returns json
language plpgsql security definer set search_path = public as $$
declare s stock_levels; pt parts; own int; take_own int; take_bn int;
begin
  perform public.require_role('unit');
  if p_qty is null or p_qty <= 0 then raise exception '수량을 1 이상으로 입력하세요.'; end if;
  select * into pt from parts where id = p_part;
  if not found then raise exception '등록되지 않은 부속입니다.'; end if;
  select on_hand into own from stock_levels where unit_id = 'MC1' and part_id = p_part for update;
  own := coalesce(own, 0);
  select * into s from stock_levels where unit_id = 'BN' and part_id = p_part for update;
  take_own := least(own, p_qty);
  take_bn := p_qty - take_own;
  if take_bn > coalesce(s.on_hand, 0) then
    raise exception '%', format('자체 재고(%s%s)와 대대 보유량(%s%s)을 합쳐도 부족합니다. 물류대대에 긴급 청구가 필요합니다.',
      own, pt.unit, coalesce(s.on_hand, 0), pt.unit);
  end if;
  if take_own > 0 then
    update stock_levels set on_hand = on_hand - take_own where unit_id = 'MC1' and part_id = p_part;
  end if;
  if take_bn > 0 then
    update stock_levels set on_hand = on_hand - take_bn where unit_id = 'BN' and part_id = p_part returning * into s;
  end if;
  insert into usage_logs (unit_id, equipment, part_id, qty, note) values ('MC1', p_equipment, p_part, p_qty, nullif(p_note, ''));
  perform public.write_log('정비부대', format('%s 정비: %s %s%s 사용 (자체 %s, 대대 불출 %s)%s', split_part(p_equipment, ' (', 1),
    pt.name, p_qty, pt.unit, take_own, take_bn, coalesce(' (' || nullif(p_note, '') || ')', '')));
  return json_build_object('on_hand', s.on_hand, 'need', s.authorized_qty > 0 and s.on_hand + s.pending <= s.reorder_point,
    'own_used', take_own, 'bn_used', take_bn, 'own_left', own - take_own);
end $$;

-- 부속 품목 추가(p_id 비움) · 수정
create or replace function public.save_part(p_id text, p_nsn text, p_name text, p_unit text, p_lead int, p_monthly int) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(p_id), '');
begin
  perform public.require_login_role('unit');
  if coalesce(trim(p_nsn), '') = '' or coalesce(trim(p_name), '') = '' then raise exception '품번과 품명을 입력하세요.'; end if;
  if p_lead is null or p_lead < 0 or p_monthly is null or p_monthly < 0 then
    raise exception '조달 소요일과 월 소모량은 0 이상의 숫자로 입력하세요.';
  end if;
  if v_id is null then
    select 'P' || lpad((coalesce(max(substring(id from 2)::int), 0) + 1)::text, 2, '0') into v_id
      from parts where id ~ '^P[0-9]+$';
    insert into parts (id, nsn, name, unit, lead_days, monthly_use)
      values (v_id, trim(p_nsn), trim(p_name), coalesce(nullif(trim(p_unit), ''), 'EA'), p_lead, p_monthly);
    insert into stock_levels (unit_id, part_id) values ('BN', v_id), ('CENTRAL', v_id), ('MC1', v_id);
    perform public.write_log('정비부대', format('부속 품목 추가: %s %s (%s)', v_id, trim(p_name), trim(p_nsn)));
  else
    update parts set nsn = trim(p_nsn), name = trim(p_name), unit = coalesce(nullif(trim(p_unit), ''), 'EA'),
      lead_days = p_lead, monthly_use = p_monthly where id = v_id;
    if not found then raise exception '없는 품목입니다.'; end if;
    perform public.write_log('정비부대', format('부속 품목 수정: %s %s (%s)', v_id, trim(p_name), trim(p_nsn)));
  end if;
  return v_id;
exception when unique_violation then
  raise exception '이미 등록된 품번입니다.';
end $$;

-- 정비부대 자체 재고 수량
create or replace function public.set_unit_stock(p_part text, p_qty int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_login_role('unit');
  if p_qty is null or p_qty < 0 then raise exception '수량은 0 이상의 숫자로 입력하세요.'; end if;
  insert into stock_levels (unit_id, part_id, on_hand) values ('MC1', p_part, p_qty)
    on conflict (unit_id, part_id) do update set on_hand = excluded.on_hand;
  perform public.write_log('정비부대', format('자체 재고 변경: %s %s%s',
    (select name from parts where id = p_part), p_qty, (select unit from parts where id = p_part)));
end $$;

-- 장비 등록(p_id 비움) · 수정
create or replace function public.save_equipment(p_id bigint, p_name text, p_active boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint := p_id;
begin
  perform public.require_login_role('unit');
  if coalesce(trim(p_name), '') = '' then raise exception '장비 이름을 입력하세요.'; end if;
  if v_id is null then
    insert into equipment (name) values (trim(p_name)) returning id into v_id;
    perform public.write_log('정비부대', format('장비 등록: %s', trim(p_name)));
  else
    update equipment set name = trim(p_name), active = coalesce(p_active, true) where id = v_id;
    if not found then raise exception '없는 장비입니다.'; end if;
    perform public.write_log('정비부대', format('장비 수정: %s%s', trim(p_name), case when p_active then '' else ' (사용 중지)' end));
  end if;
  return v_id;
end $$;

-- 처음 상태로: 정비부대 자체 재고도 되돌림 (품목·장비 목록은 유지)
create or replace function public.reset_demo() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.public_mode() and public.my_role() <> 'admin' then
    raise exception '관리자만 처음 상태로 되돌릴 수 있습니다.';
  end if;
  perform public.seed_demo();
  update stock_levels set on_hand = case part_id when 'P01' then 2 when 'P06' then 1 else 0 end where unit_id = 'MC1';
end $$;

-- 권한: 관리 함수는 로그인 사용자만
revoke execute on function public.require_login_role(text[]) from public, anon, authenticated;
revoke execute on function public.save_part(text, text, text, text, int, int), public.set_unit_stock(text, int),
  public.save_equipment(bigint, text, boolean) from public, anon;
grant execute on function public.save_part(text, text, text, text, int, int), public.set_unit_stock(text, int),
  public.save_equipment(bigint, text, boolean) to authenticated;
