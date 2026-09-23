-- ============================================================
-- 家相册 · Supabase 数据库初始化脚本
-- 使用方法：Supabase 后台 → SQL Editor → New query → 粘贴运行
-- ============================================================

-- 1) 家族表
create table if not exists public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

-- 2) 家族成员表
create table if not exists public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

-- 3) 照片视频表
create table if not exists public.media (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  uploader_id uuid not null references auth.users(id) on delete cascade,
  uploader_name text not null default '家人',
  type text not null check (type in ('photo','video')),
  storage_path text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_media_family on public.media (family_id, created_at desc);

-- 4) 开启行级安全（数据只对家族成员可见）
alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.media enable row level security;

-- 5) 家族表策略
drop policy if exists "families_select_member" on public.families;
create policy "families_select_member" on public.families
  for select using (
    exists (select 1 from public.family_members fm
            where fm.family_id = families.id and fm.user_id = auth.uid())
  );
drop policy if exists "families_insert_any_user" on public.families;
create policy "families_insert_any_user" on public.families
  for insert with check (auth.role() = 'authenticated');

-- 6) 成员表策略
drop policy if exists "members_select_own" on public.family_members;
create policy "members_select_own" on public.family_members
  for select using (auth.uid() = user_id);
drop policy if exists "members_insert_own" on public.family_members;
create policy "members_insert_own" on public.family_members
  for insert with check (auth.uid() = user_id);

-- 7) 通过邀请码加入家族（安全函数，返回家族 id）
create or replace function public.join_family_by_code(p_code text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_family_id uuid;
begin
  select id into v_family_id from public.families where invite_code = upper(trim(p_code));
  if v_family_id is null then
    raise exception '邀请码不存在';
  end if;
  insert into public.family_members (family_id, user_id)
  values (v_family_id, auth.uid())
  on conflict (family_id, user_id) do nothing;
  return v_family_id;
end $$;
grant execute on function public.join_family_by_code(text) to authenticated;

-- 8) 媒体表策略
drop policy if exists "media_select_member" on public.media;
create policy "media_select_member" on public.media
  for select using (
    exists (select 1 from public.family_members fm
            where fm.family_id = media.family_id and fm.user_id = auth.uid())
  );
drop policy if exists "media_insert_member" on public.media;
create policy "media_insert_member" on public.media
  for insert with check (
    uploader_id = auth.uid() and
    exists (select 1 from public.family_members fm
            where fm.family_id = media.family_id and fm.user_id = auth.uid())
  );
drop policy if exists "media_delete_own" on public.media;
create policy "media_delete_own" on public.media
  for delete using (uploader_id = auth.uid());

-- 9) 存储桶：family-album（公开读，仅登录用户可上传/删除）
insert into storage.buckets (id, name, public)
values ('family-album', 'family-album', true)
on conflict (id) do nothing;

drop policy if exists "album_public_read" on storage.objects;
create policy "album_public_read" on storage.objects
  for select using (bucket_id = 'family-album');
drop policy if exists "album_auth_insert" on storage.objects;
create policy "album_auth_insert" on storage.objects
  for insert with check (bucket_id = 'family-album' and auth.role() = 'authenticated');
drop policy if exists "album_auth_update" on storage.objects;
create policy "album_auth_update" on storage.objects
  for update using (bucket_id = 'family-album' and auth.role() = 'authenticated');
drop policy if exists "album_owner_delete" on storage.objects;
create policy "album_owner_delete" on storage.objects
  for delete using (bucket_id = 'family-album' and owner = auth.uid());
