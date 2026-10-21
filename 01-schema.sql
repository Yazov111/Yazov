-- ============================================================
-- 理想螺旋 · Supabase 初始化脚本
-- 用法：Supabase Dashboard → SQL Editor → New query → 全文粘贴 → Run
-- 幂等性：使用了 if not exists / or replace，可重复执行
-- ============================================================

-- ---------- 1. 表 ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_config (
  key text primary key,
  value text
);

create table if not exists public.submissions (
  id bigint generated always as identity primary key,
  owner_id text not null,
  owner_name text,
  author_name text,
  email text,
  section text not null,
  subsection text,
  title text not null,
  bio text,
  content text,
  images text,
  status text not null default 'pending',
  parent_id bigint,
  chapter_no int not null default 1,
  is_original boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists sub_status_idx on public.submissions (status, created_at);
create index if not exists sub_section_idx on public.submissions (section);
create index if not exists sub_parent_idx on public.submissions (parent_id);

create table if not exists public.piece_images (
  id bigint generated always as identity primary key,
  submission_id bigint not null references public.submissions(id) on delete cascade,
  sort_no int not null default 1,
  data_url text not null,
  caption text
);
create index if not exists img_sub_idx on public.piece_images (submission_id, sort_no);

create table if not exists public.comments (
  id bigint generated always as identity primary key,
  piece_id bigint not null references public.submissions(id) on delete cascade,
  user_id text not null default auth.uid()::text,
  user_name text,
  content text not null,
  parent_id bigint,
  created_at timestamptz not null default now()
);
create index if not exists cmt_piece_idx on public.comments (piece_id, created_at);

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id text not null,
  type text not null default 'comment',
  actor_name text,
  piece_id bigint,
  piece_title text,
  comment_id bigint,
  excerpt text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notif_user_idx on public.notifications (user_id, created_at);

-- ---------- 2. 函数 ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid());
$fn$;

create or replace function public.owns_piece(pid bigint) returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select exists (select 1 from public.submissions s where s.id = pid and s.owner_id = auth.uid()::text);
$fn$;

create or replace function public.claim_admin(p_code text) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare ok boolean;
begin
  select value = p_code into ok from public.admin_config where key = 'invite_code';
  if ok is true then
    insert into public.admins (user_id) values (auth.uid()) on conflict do nothing;
  end if;
  return coalesce(ok, false);
end;
$fn$;

-- 用户注册后按邮箱认领自己在此前的旧投稿
create or replace function public.claim_owned_pieces() returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare n int;
begin
  update public.submissions
     set owner_id = auth.uid()::text
   where email = (select email from auth.users where id = auth.uid())
     and owner_id <> auth.uid()::text;
  get diagnostics n = row_count;
  return n;
end;
$fn$;

-- 评论 → 通知（一级评论通知作品作者；回复通知被回复人）
create or replace function public.notify_on_comment() returns trigger
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_owner text;
  v_title text;
  v_parent_user text;
begin
  select s.owner_id, s.title into v_owner, v_title from public.submissions s where s.id = new.piece_id;
  if new.parent_id is not null then
    select c.user_id into v_parent_user from public.comments c where c.id = new.parent_id;
    if v_parent_user is not null and v_parent_user <> new.user_id then
      insert into public.notifications (user_id, type, actor_name, piece_id, piece_title, comment_id, excerpt)
      values (v_parent_user, 'reply', new.user_name, new.piece_id, v_title, new.id, left(new.content, 60));
    end if;
  else
    if v_owner is not null and v_owner <> new.user_id then
      insert into public.notifications (user_id, type, actor_name, piece_id, piece_title, comment_id, excerpt)
      values (v_owner, 'comment', new.user_name, new.piece_id, v_title, new.id, left(new.content, 60));
    end if;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_notify_comment on public.comments;
create trigger trg_notify_comment after insert on public.comments
for each row execute function public.notify_on_comment();

-- ---------- 3. RLS ----------
alter table public.profiles enable row level security;
drop policy if exists prof_select on public.profiles;
create policy prof_select on public.profiles for select to authenticated using (true);
drop policy if exists prof_insert on public.profiles;
create policy prof_insert on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists prof_update on public.profiles;
create policy prof_update on public.profiles for update to authenticated using (id = auth.uid());

alter table public.admins enable row level security;
drop policy if exists admins_select on public.admins;
create policy admins_select on public.admins for select to authenticated using (true);

alter table public.admin_config enable row level security;
-- admin_config 无任何策略：仅安全定义者函数可读

alter table public.submissions enable row level security;
drop policy if exists sub_select on public.submissions;
create policy sub_select on public.submissions for select to authenticated
  using (owner_id = auth.uid()::text or public.is_admin());
drop policy if exists sub_insert on public.submissions;
create policy sub_insert on public.submissions for insert to authenticated
  with check (owner_id = auth.uid()::text and (parent_id is null or public.owns_piece(parent_id)));
drop policy if exists sub_update on public.submissions;
create policy sub_update on public.submissions for update to authenticated
  using (owner_id = auth.uid()::text or public.is_admin())
  with check (owner_id = auth.uid()::text or public.is_admin());
drop policy if exists sub_delete on public.submissions;
create policy sub_delete on public.submissions for delete to authenticated
  using (owner_id = auth.uid()::text or public.is_admin());

alter table public.piece_images enable row level security;
drop policy if exists img_select on public.piece_images;
create policy img_select on public.piece_images for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.submissions s
    where s.id = piece_images.submission_id
      and (s.owner_id = auth.uid()::text or s.status = 'accepted')));
drop policy if exists img_insert on public.piece_images;
create policy img_insert on public.piece_images for insert to authenticated
  with check (public.owns_piece(submission_id));

alter table public.comments enable row level security;
drop policy if exists cmt_select on public.comments;
create policy cmt_select on public.comments for select to authenticated using (true);
drop policy if exists cmt_insert on public.comments;
create policy cmt_insert on public.comments for insert to authenticated
  with check (user_id = auth.uid()::text);
drop policy if exists cmt_delete on public.comments;
create policy cmt_delete on public.comments for delete to authenticated
  using (user_id = auth.uid()::text or public.is_admin());

alter table public.notifications enable row level security;
drop policy if exists notif_select on public.notifications;
create policy notif_select on public.notifications for select to authenticated using (user_id = auth.uid()::text);
drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications for update to authenticated using (user_id = auth.uid()::text) with check (user_id = auth.uid()::text);
drop policy if exists notif_delete on public.notifications;
create policy notif_delete on public.notifications for delete to authenticated using (user_id = auth.uid()::text);

-- ---------- 4. 公开视图（默认 security_invoker = off，以属主权限绕过 RLS 供匿名读取） ----------
drop view if exists public.published_pieces;
create view public.published_pieces as
  select id, title, section, subsection, author_name, bio, content, images, parent_id, chapter_no, is_original, created_at
  from public.submissions where status = 'accepted';

drop view if exists public.piece_images_public;
create view public.piece_images_public as
  select i.id, i.submission_id, i.sort_no, i.data_url, i.caption
  from public.piece_images i
  join public.submissions s on s.id = i.submission_id
  where s.status = 'accepted';

drop view if exists public.piece_comments;
create view public.piece_comments as
  select id, piece_id, user_id, user_name, content, parent_id, created_at
  from public.comments;

grant select on public.published_pieces to anon, authenticated;
grant select on public.piece_images_public to anon, authenticated;
grant select on public.piece_comments to anon, authenticated;

-- ---------- 5. 管理员邀请码 ----------
insert into public.admin_config (key, value) values ('invite_code', 'SIWEN-S8Y1-JI5O')
on conflict (key) do update set value = excluded.value;

-- ---------- 6. 现有数据迁移 ----------

-- 跑完 01 后，确认左侧 Table Editor 里出现 7 张表
