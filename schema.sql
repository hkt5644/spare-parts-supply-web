-- 수리부속 순환보급체계 스키마 (가상 데이터)
-- 정비부대 → 중간 물류대대 → 중앙 물류 → 조달

create table units (
  id text primary key,
  name text not null,
  level text not null check (level in ('maintenance', 'battalion', 'central')),
  parent_id text references units(id)
);

create table parts (
  id text primary key,
  nsn text not null unique,
  name text not null,
  unit text not null default 'EA',
  lead_days int not null default 14,
  monthly_use int not null default 0
);

-- 부대 × 품목별 정수와 재고
create table stock_levels (
  unit_id text references units(id),
  part_id text references parts(id),
  on_hand int not null default 0 check (on_hand >= 0),
  pending int not null default 0 check (pending >= 0),
  authorized_qty int not null default 0,
  reorder_point int not null default 0,
  primary key (unit_id, part_id),
  check (reorder_point < authorized_qty or authorized_qty = 0)
);

create table usage_logs (
  id bigint generated always as identity primary key,
  unit_id text not null references units(id),
  equipment text not null,
  part_id text not null references parts(id),
  qty int not null check (qty > 0),
  note text,
  created_at timestamptz not null default now()
);

create table requisitions (
  id text primary key,
  from_unit text not null references units(id),
  to_unit text not null references units(id),
  type text not null check (type in ('자동', '수동', '긴급')),
  status text not null default '확인대기' check (status in ('확인대기', '중앙접수', '처리중', '완료', '취소')),
  created_at timestamptz not null default now()
);

create table requisition_items (
  id bigint generated always as identity primary key,
  requisition_id text not null references requisitions(id) on delete cascade,
  part_id text not null references parts(id),
  qty int not null check (qty > 0),
  issued int not null default 0,
  backorder int not null default 0,
  received int not null default 0
);

create table shipments (
  id text primary key,
  requisition_id text not null references requisitions(id),
  part_id text not null references parts(id),
  qty int not null check (qty > 0),
  status text not null default '수송중' check (status in ('수송중', '수령완료')),
  created_at timestamptz not null default now()
);

create table procurements (
  id text primary key,
  part_id text not null references parts(id),
  qty int not null check (qty > 0),
  status text not null default '요청' check (status in ('요청', '계약진행', '입고완료')),
  requisition_refs text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table status_history (
  id bigint generated always as identity primary key,
  actor text not null,
  message text not null,
  created_at timestamptz not null default now()
);

-- 모든 테이블 RLS 사용 (정책이 없으면 외부 접근 차단. 앱 연동 때 로그인 기반 정책 추가)
alter table units enable row level security;
alter table parts enable row level security;
alter table stock_levels enable row level security;
alter table usage_logs enable row level security;
alter table requisitions enable row level security;
alter table requisition_items enable row level security;
alter table shipments enable row level security;
alter table procurements enable row level security;
alter table status_history enable row level security;

-- 가상 기초 데이터
insert into units (id, name, level, parent_id) values
  ('CENTRAL', '중앙 물류', 'central', null),
  ('BN', '중간 물류대대', 'battalion', 'CENTRAL'),
  ('MC1', '제1정비중대', 'maintenance', 'BN');

insert into parts (id, nsn, name, unit, lead_days, monthly_use) values
  ('P01', '2940-00-000-0101', '엔진오일 필터', 'EA', 14, 18),
  ('P02', '2910-00-000-0102', '연료 필터', 'EA', 30, 9),
  ('P03', '2530-00-000-0103', '브레이크 패드', 'SET', 21, 6),
  ('P04', '6140-00-000-0104', '배터리 12V 100Ah', 'EA', 10, 4),
  ('P05', '2610-00-000-0105', '타이어 335/80R20', 'EA', 45, 5),
  ('P06', '3030-00-000-0106', '팬벨트', 'EA', 14, 7),
  ('P07', '4720-00-000-0107', '유압 호스 1/2"', 'EA', 60, 3),
  ('P08', '6220-00-000-0108', '전조등 어셈블리', 'EA', 20, 4);

insert into stock_levels (unit_id, part_id, on_hand, pending, authorized_qty, reorder_point) values
  ('BN', 'P01', 9, 0, 30, 12),
  ('BN', 'P02', 10, 0, 24, 10),
  ('BN', 'P03', 4, 0, 16, 6),
  ('BN', 'P04', 3, 6, 10, 4),
  ('BN', 'P05', 20, 0, 20, 8),
  ('BN', 'P06', 11, 0, 18, 6),
  ('BN', 'P07', 3, 8, 12, 4),
  ('BN', 'P08', 9, 0, 14, 5),
  ('CENTRAL', 'P01', 40, 0, 0, 0),
  ('CENTRAL', 'P02', 0, 0, 0, 0),
  ('CENTRAL', 'P03', 5, 0, 0, 0),
  ('CENTRAL', 'P04', 12, 0, 0, 0),
  ('CENTRAL', 'P05', 30, 0, 0, 0),
  ('CENTRAL', 'P06', 25, 0, 0, 0),
  ('CENTRAL', 'P07', 0, 0, 0, 0),
  ('CENTRAL', 'P08', 8, 0, 0, 0);
