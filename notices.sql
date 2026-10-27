-- 6단계: 공지사항 (stock_number.sql 다음에 실행)
-- 누구나 읽을 수 있고, 쓰기·수정·삭제는 로그인한 관리자만 할 수 있다.

create table notices (
  id bigint generated always as identity primary key,
  title text not null,
  body text not null default '',
  pinned boolean not null default false,
  author text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table notices enable row level security;
create policy "승인된 사용자 조회" on notices for select to authenticated
  using (public.my_role() not in ('pending', 'anon'));
create policy "공개 모드 조회" on notices for select to anon, authenticated
  using (public.public_mode());

insert into notices (title, body, pinned, author) values
  ('수리부속 순환보급체계 사용 안내',
   '정비부대에서 사용 등록 → 물류대대 정수 확인·자동 청구 → 중앙 물류 출고 → 조달 순서로 처리합니다.' || chr(10) ||
   '장비와 부속 품목은 부여받은 재고번호(숫자 13자리)로 등록하세요.', true, '관리자');

-- 공지 작성(p_id 비움) · 수정
create or replace function public.save_notice(p_id bigint, p_title text, p_body text, p_pinned boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint := p_id; v_author text;
begin
  perform public.require_login_role('admin');
  if coalesce(trim(p_title), '') = '' then raise exception '제목을 입력하세요.'; end if;
  select coalesce(email, '관리자') into v_author from profiles where id = auth.uid();
  if v_id is null then
    insert into notices (title, body, pinned, author)
      values (trim(p_title), coalesce(p_body, ''), coalesce(p_pinned, false), coalesce(v_author, '관리자'))
      returning id into v_id;
    perform public.write_log('관리자', format('공지 등록: %s', trim(p_title)));
  else
    update notices set title = trim(p_title), body = coalesce(p_body, ''), pinned = coalesce(p_pinned, false),
      updated_at = now() where id = v_id;
    if not found then raise exception '없는 공지입니다.'; end if;
    perform public.write_log('관리자', format('공지 수정: %s', trim(p_title)));
  end if;
  return v_id;
end $$;

create or replace function public.delete_notice(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_title text;
begin
  perform public.require_login_role('admin');
  delete from notices where id = p_id returning title into v_title;
  if not found then raise exception '없는 공지입니다.'; end if;
  perform public.write_log('관리자', format('공지 삭제: %s', v_title));
end $$;

revoke execute on function public.save_notice(bigint, text, text, boolean), public.delete_notice(bigint) from public, anon;
grant execute on function public.save_notice(bigint, text, text, boolean), public.delete_notice(bigint) to authenticated;
