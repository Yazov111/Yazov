-- 09 管理员分级：超级管理员可任命/撤销其他管理员
-- 超级管理员 = admins.is_super = true（站长的账号）

alter table public.admins add column if not exists is_super boolean not null default false;

-- 把站长账号设为超级管理员（若 admins 为空则跳过此步，由下方 insert 兜底）
update public.admins a
   set is_super = true
 where a.user_id in (select id from auth.users where email = '482742624@qq.com')
   and not exists (select 1 from public.admins where is_super);

-- 兜底：若该邮箱尚未认领管理员，直接写入为超级管理员
insert into public.admins (user_id, is_super)
select u.id, true from auth.users u where u.email = '482742624@qq.com'
on conflict (user_id) do update set is_super = true;

-- 当前登录者是否超级管理员
create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid() and is_super);
$fn$;

-- 列出全部管理员（仅登录用户可调；前端用于显示状态）
create or replace function public.list_admin_ids() returns table(user_id uuid, is_super boolean)
language sql stable security definer set search_path to 'public' as $fn$
  select user_id, is_super from public.admins;
$fn$;

-- 任命 / 撤销管理员（仅超级管理员可调；不能撤销任何超级管理员）
create or replace function public.set_admin(p_user_id uuid, p_admin boolean) returns void
language plpgsql security definer set search_path to 'public' as $fn$
declare v_target_super boolean;
begin
  if not public.is_super_admin() then
    raise exception 'FORBIDDEN: only super admin can manage admins';
  end if;
  select is_super into v_target_super from public.admins where user_id = p_user_id;
  if p_admin then
    insert into public.admins (user_id, is_super) values (p_user_id, false)
    on conflict (user_id) do nothing;
  else
    if v_target_super is true then
      raise exception 'FORBIDDEN: cannot revoke a super admin';
    end if;
    delete from public.admins where user_id = p_user_id;
  end if;
end;
$fn$;

grant execute on function public.is_super_admin() to authenticated;
grant execute on function public.list_admin_ids() to authenticated;
grant execute on function public.set_admin(uuid, boolean) to authenticated;
