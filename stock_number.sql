-- 5단계: 재고번호 13자리 (unit_manage.sql 다음에 실행)
-- 장비와 부속 품목은 부여받은 재고번호(숫자 13자리)로 등록한다. 저장 형식: 0000-00-000-0000

-- 숫자만 골라 13자리인지 확인하고 0000-00-000-0000 형식으로 맞춘다
create or replace function public.normalize_nsn(p text) returns text
language plpgsql immutable set search_path = public as $$
declare d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if length(d) <> 13 then raise exception '재고번호는 숫자 13자리로 입력하세요. (입력: %자리)', length(d); end if;
  return substr(d, 1, 4) || '-' || substr(d, 5, 2) || '-' || substr(d, 7, 3) || '-' || substr(d, 10, 4);
end $$;

update parts set nsn = public.normalize_nsn(nsn);
alter table parts add constraint parts_nsn_13 check (nsn ~ '^[0-9]{4}-[0-9]{2}-[0-9]{3}-[0-9]{4}$');

alter table equipment add column nsn text;
update equipment set nsn = case name
  when '전술차량 A형 (가상-101)' then '2320-00-000-0101'
  when '전술차량 B형 (가상-207)' then '2320-00-000-0207'
  when '발전기 10kW (가상-G03)' then '6115-00-000-0003'
  when '지게차 3톤 (가상-F12)' then '3930-00-000-0012'
  else '9999-00-000-' || lpad(id::text, 4, '0') end;
alter table equipment alter column nsn set not null;
alter table equipment add constraint equipment_nsn_key unique (nsn);
alter table equipment add constraint equipment_nsn_13 check (nsn ~ '^[0-9]{4}-[0-9]{2}-[0-9]{3}-[0-9]{4}$');

-- 부속 품목 추가(p_id 비움) · 수정: 재고번호 13자리 필수
create or replace function public.save_part(p_id text, p_nsn text, p_name text, p_unit text, p_lead int, p_monthly int) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(p_id), ''); v_nsn text;
begin
  perform public.require_login_role('unit');
  v_nsn := public.normalize_nsn(p_nsn);
  if coalesce(trim(p_name), '') = '' then raise exception '품명을 입력하세요.'; end if;
  if p_lead is null or p_lead < 0 or p_monthly is null or p_monthly < 0 then
    raise exception '조달 소요일과 월 소모량은 0 이상의 숫자로 입력하세요.';
  end if;
  if v_id is null then
    select 'P' || lpad((coalesce(max(substring(id from 2)::int), 0) + 1)::text, 2, '0') into v_id
      from parts where id ~ '^P[0-9]+$';
    insert into parts (id, nsn, name, unit, lead_days, monthly_use)
      values (v_id, v_nsn, trim(p_name), coalesce(nullif(trim(p_unit), ''), 'EA'), p_lead, p_monthly);
    insert into stock_levels (unit_id, part_id) values ('BN', v_id), ('CENTRAL', v_id), ('MC1', v_id);
    perform public.write_log('정비부대', format('부속 품목 추가: %s %s', v_nsn, trim(p_name)));
  else
    update parts set nsn = v_nsn, name = trim(p_name), unit = coalesce(nullif(trim(p_unit), ''), 'EA'),
      lead_days = p_lead, monthly_use = p_monthly where id = v_id;
    if not found then raise exception '없는 품목입니다.'; end if;
    perform public.write_log('정비부대', format('부속 품목 수정: %s %s', v_nsn, trim(p_name)));
  end if;
  return v_nsn;
exception when unique_violation then
  raise exception '이미 등록된 재고번호입니다.';
end $$;

-- 장비 등록(p_id 비움) · 수정: 재고번호 13자리 필수
drop function public.save_equipment(bigint, text, boolean);
create function public.save_equipment(p_id bigint, p_nsn text, p_name text, p_active boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_id bigint := p_id; v_nsn text;
begin
  perform public.require_login_role('unit');
  v_nsn := public.normalize_nsn(p_nsn);
  if coalesce(trim(p_name), '') = '' then raise exception '장비명을 입력하세요.'; end if;
  if v_id is null then
    insert into equipment (nsn, name) values (v_nsn, trim(p_name));
    perform public.write_log('정비부대', format('장비 등록: %s %s', v_nsn, trim(p_name)));
  else
    update equipment set nsn = v_nsn, name = trim(p_name), active = coalesce(p_active, true) where id = v_id;
    if not found then raise exception '없는 장비입니다.'; end if;
    perform public.write_log('정비부대', format('장비 수정: %s %s%s', v_nsn, trim(p_name),
      case when p_active then '' else ' (사용 중지)' end));
  end if;
  return v_nsn;
exception when unique_violation then
  raise exception '이미 등록된 재고번호입니다.';
end $$;

revoke execute on function public.save_equipment(bigint, text, text, boolean) from public, anon;
grant execute on function public.save_equipment(bigint, text, text, boolean) to authenticated;
