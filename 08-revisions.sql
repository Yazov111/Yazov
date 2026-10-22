-- 08 修改文章功能：piece_revisions 表
-- 作者对已刊出稿件提交修改 → 管理员审核通过后写回原稿
-- 审核期间原文保持可见（不退回、不下架）

create table if not exists public.piece_revisions (
  id bigint generated always as identity primary key,
  piece_id bigint not null references public.submissions(id) on delete cascade,
  author_id text not null,
  title text not null,
  content text,
  status text not null default 'pending',
  review_note text,
  created_at timestamptz not null default now()
);
create index if not exists rev_piece_idx on public.piece_revisions (piece_id, created_at);
create index if not exists rev_status_idx on public.piece_revisions (status, created_at);

alter table public.piece_revisions enable row level security;
drop policy if exists rev_select on public.piece_revisions;
create policy rev_select on public.piece_revisions for select to authenticated
  using (author_id = auth.uid()::text or public.is_admin());
drop policy if exists rev_insert on public.piece_revisions;
create policy rev_insert on public.piece_revisions for insert to authenticated
  with check (author_id = auth.uid()::text and public.owns_piece(piece_id));
drop policy if exists rev_update on public.piece_revisions;
create policy rev_update on public.piece_revisions for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists rev_delete on public.piece_revisions;
create policy rev_delete on public.piece_revisions for delete to authenticated
  using (public.is_admin());

-- 管理员一键通过：把修改写回原稿并标记 applied
create or replace function public.apply_revision(p_rev bigint) returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare r record;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN: only admins can apply revisions';
  end if;
  select * into r from public.piece_revisions where id = p_rev and status = 'pending';
  if r.id is null then
    raise exception 'NOT_FOUND: revision not found or already handled';
  end if;
  update public.submissions
     set title = r.title,
         content = r.content
   where id = r.piece_id;
  update public.piece_revisions set status = 'applied' where id = p_rev;
end;
$fn$;
grant execute on function public.apply_revision(bigint) to authenticated;
