-- 3단계: 공개 모드 (auth.sql 다음에 실행)
-- 공개 모드가 켜져 있으면 로그인하지 않은 사람도 모든 화면을 보고 업무 처리를 할 수 있다.
-- 사용자 역할 변경(set_user_role)은 공개 모드에서도 관리자만 할 수 있다.
-- 끄기: update public.app_settings set public_mode = false;

create table app_settings (
  id int primary key default 1 check (id = 1),
  public_mode boolean not null default false
);
alter table app_settings enable row level security;
insert into app_settings (id, public_mode) values (1, true);

create or replace function public.public_mode() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public_mode from public.app_settings where id = 1), false)
$$;

create or replace function public.require_role(variadic allowed text[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare r text := public.my_role();
begin
  if public.public_mode() then return; end if;
  if r <> 'admin' and not (r = any(allowed)) then
    raise exception '이 작업을 할 권한이 없습니다 (현재 역할: %)', r;
  end if;
end $$;

create or replace function public.reset_demo() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.public_mode() and public.my_role() <> 'admin' then
    raise exception '관리자만 처음 상태로 되돌릴 수 있습니다.';
  end if;
  perform public.seed_demo();
end $$;

do $$
declare t text;
begin
  foreach t in array array['units', 'parts', 'stock_levels', 'usage_logs', 'requisitions',
                           'requisition_items', 'shipments', 'procurements', 'status_history'] loop
    execute format('create policy "공개 모드 조회" on public.%I for select to anon, authenticated
                    using (public.public_mode())', t);
  end loop;
end $$;

revoke execute on function public.public_mode() from public;
grant execute on function public.public_mode() to anon, authenticated;
grant execute on function public.use_parts(text, text, int, text), public.auto_requisition(),
  public.confirm_requisition(text), public.cancel_requisition(text), public.process_requisition(text),
  public.advance_procurement(text), public.receive_shipment(text), public.set_stock_level(text, int, int),
  public.reset_demo() to anon;
