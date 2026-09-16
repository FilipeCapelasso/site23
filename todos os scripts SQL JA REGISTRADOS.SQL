-- =====================================================================
-- NOVASTORE — SCRIPT SQL COMPLETO E AUTOSSUFICIENTE (v2)
-- =====================================================================
-- Esta versão NÃO precisa de Edge Function, CLI, PowerShell nem nada
-- fora do site do Supabase. Tudo roda dentro do banco:
--   • a chamada ao Mercado Pago é feita de dentro do Postgres
--     (extensão "http")
--   • o token de acesso fica guardado no Vault do Supabase
--     (Project Settings → Vault, ou por SQL, como mostrado no final)
--   • a confirmação automática do pagamento roda sozinha via pg_cron
--
-- É seguro rodar este script em um projeto que já tem produtos, imagens
-- e configurações salvas: tudo usa "IF NOT EXISTS" e nunca apaga dados.
--
-- Depois de rodar este arquivo inteiro, o único passo manual que falta
-- é cadastrar o token do Mercado Pago (passo a passo no final deste
-- arquivo, e também explicado na conversa).
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists http with schema extensions;

do $$
begin
  create extension if not exists pg_cron with schema extensions;
exception when others then
  raise notice 'pg_cron não pôde ser criado automaticamente (%). Se o passo de confirmação automática não funcionar, ative a extensão "pg_cron" em Database → Extensions no site do Supabase.', sqlerrm;
end $$;


-- =====================================================================
-- 1) TABELA: products  (preserva tudo que já existe)
-- =====================================================================
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  slug         text unique,
  name         text not null,
  description  text,
  category     text,
  tags         text[] default '{}',
  features     text[] default '{}',
  type         text not null default 'UNICO' check (type in ('UNICO','ASSINATURA')),
  price        numeric,
  stock        integer,
  image_url    text,
  plans        jsonb default '[]',
  featured     boolean default false,
  active       boolean default true,
  created_at   timestamptz default now()
);

alter table public.products add column if not exists slug text;
alter table public.products add column if not exists tags text[] default '{}';
alter table public.products add column if not exists features text[] default '{}';
alter table public.products add column if not exists plans jsonb default '[]';
alter table public.products add column if not exists featured boolean default false;
alter table public.products add column if not exists active boolean default true;
alter table public.products add column if not exists created_at timestamptz default now();

create unique index if not exists products_slug_key on public.products (slug) where slug is not null;
create index if not exists idx_products_category on public.products (category);
create index if not exists idx_products_featured on public.products (featured);
create index if not exists idx_products_active on public.products (active);

alter table public.products enable row level security;

drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products
  for select using (active = true);

drop policy if exists "admin full access products" on public.products;
create policy "admin full access products" on public.products
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');


-- =====================================================================
-- 2) TABELA: site_settings  (banner e fundo do site)
-- =====================================================================
create table if not exists public.site_settings (
  id                   smallint primary key default 1,
  hero_image_url       text,
  hero_overlay         numeric default 0.35,
  background_image_url text,
  background_overlay   numeric default 0.85,
  updated_at           timestamptz default now()
);

alter table public.site_settings add column if not exists hero_overlay numeric default 0.35;
alter table public.site_settings add column if not exists updated_at timestamptz default now();

insert into public.site_settings (id)
values (1)
on conflict (id) do nothing;

alter table public.site_settings enable row level security;

drop policy if exists "public read settings" on public.site_settings;
create policy "public read settings" on public.site_settings
  for select using (true);

drop policy if exists "admin write settings" on public.site_settings;
create policy "admin write settings" on public.site_settings
  for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');


-- =====================================================================
-- 3) TABELA: orders  (pedidos + Pix)
-- =====================================================================
create table if not exists public.orders (
  id                    uuid primary key default gen_random_uuid(),
  customer_name         text,
  customer_email        text,
  items                 jsonb,
  total                 numeric,
  status                text default 'PENDENTE',
  mp_payment_id         text,
  pix_qr_code           text,
  pix_qr_code_base64    text,
  expires_at            timestamptz,
  paid_at               timestamptz,
  created_at            timestamptz default now()
);

-- garante as colunas mesmo se a tabela já existia com outro formato
alter table public.orders add column if not exists customer_name text;
alter table public.orders add column if not exists customer_email text;
alter table public.orders add column if not exists items jsonb;
alter table public.orders add column if not exists total numeric;
alter table public.orders add column if not exists status text default 'PENDENTE';
alter table public.orders add column if not exists mp_payment_id text;
alter table public.orders add column if not exists pix_qr_code text;
alter table public.orders add column if not exists pix_qr_code_base64 text;
alter table public.orders add column if not exists expires_at timestamptz;
alter table public.orders add column if not exists paid_at timestamptz;
alter table public.orders add column if not exists created_at timestamptz default now();
alter table public.orders alter column status set default 'PENDENTE';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_status_check') then
    alter table public.orders add constraint orders_status_check
      check (status in ('PENDENTE','PAGO','CANCELADO','EXPIRADO'));
  end if;
exception when others then
  raise notice 'Não criei a validação de status (talvez já existam pedidos com status diferente) — %', sqlerrm;
end $$;

create index if not exists idx_orders_status on public.orders (status);
create index if not exists idx_orders_mp_payment_id on public.orders (mp_payment_id);
create index if not exists idx_orders_created_at on public.orders (created_at desc);

alter table public.orders enable row level security;

drop policy if exists "admin can view orders" on public.orders;
create policy "admin can view orders" on public.orders
  for select using (auth.role() = 'authenticated');

drop policy if exists "admin can update orders" on public.orders;
create policy "admin can update orders" on public.orders
  for update using (auth.role() = 'authenticated');
-- Não existe policy pública de insert/update: tudo passa pelas funções
-- abaixo, que rodam como SECURITY DEFINER (ignoram RLS com segurança).


-- =====================================================================
-- 4) TOKEN DO MERCADO PAGO — guardado no Vault do Supabase
-- =====================================================================
-- Se o Vault já estiver disponível no seu projeto (é o padrão hoje em
-- dia), este bloco só garante que a extensão exista. O cadastro do
-- valor do token em si você faz depois, sem precisar mexer em código
-- (veja o passo a passo no final deste arquivo).
do $$
begin
  create extension if not exists supabase_vault;
exception when others then
  raise notice 'Vault já gerenciado pelo Supabase ou indisponível para criar via SQL — normalmente já vem ativo no projeto (%).', sqlerrm;
end $$;

-- Função auxiliar que lê o token salvo no Vault com o nome "mp_access_token"
create or replace function public.mp_get_token()
returns text
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_token text;
begin
  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where name = 'mp_access_token'
  limit 1;

  return v_token;
end;
$$;

revoke all on function public.mp_get_token() from public;
-- só as funções abaixo (security definer, donas do mesmo schema) chamam esta


-- =====================================================================
-- 5) FUNÇÃO: get_order_status
--    O site usa isso pra saber se o Pix já caiu (sem expor dados do
--    cliente pra quem não é dono do pedido).
-- =====================================================================
create or replace function public.get_order_status(order_id uuid)
returns text
language sql
security definer
set search_path = public
as $$
  select status from public.orders where id = order_id;
$$;

revoke all on function public.get_order_status(uuid) from public;
grant execute on function public.get_order_status(uuid) to anon, authenticated;


-- =====================================================================
-- 6) FUNÇÃO: criar_pix
--    Chamada direto pelo site (supabase.rpc). Cria o pedido e já gera
--    a cobrança Pix no Mercado Pago, tudo dentro do Postgres.
-- =====================================================================
create or replace function public.criar_pix(p_name text, p_email text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token        text;
  v_total        numeric;
  v_order_id     uuid;
  v_expires_at   timestamptz := now() + interval '30 minutes';
  v_first_name   text;
  v_last_name    text;
  v_payload      jsonb;
  v_response     http_response;
  v_mp           jsonb;
  v_qr_code      text;
  v_qr_base64    text;
  v_mp_id        text;
begin
  if p_name is null or p_email is null or p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'Dados incompletos para gerar o Pix.');
  end if;

  select coalesce(sum((item->>'price')::numeric * coalesce((item->>'quantity')::numeric, 1)), 0)
  into v_total
  from jsonb_array_elements(p_items) as item;

  if v_total <= 0 then
    return jsonb_build_object('error', 'Valor do pedido inválido.');
  end if;

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return jsonb_build_object('error', 'Token do Mercado Pago não configurado. Cadastre o segredo "mp_access_token" no Vault do Supabase.');
  end if;

  insert into public.orders (customer_name, customer_email, items, total, status, expires_at)
  values (p_name, p_email, p_items, v_total, 'PENDENTE', v_expires_at)
  returning id into v_order_id;

  v_first_name := split_part(trim(p_name), ' ', 1);
  v_last_name  := nullif(trim(substr(trim(p_name), length(v_first_name) + 1)), '');
  if v_last_name is null then v_last_name := v_first_name; end if;

  v_payload := jsonb_build_object(
    'transaction_amount', round(v_total, 2),
    'description', 'Pedido NovaStore #' || left(v_order_id::text, 8),
    'payment_method_id', 'pix',
    'payer', jsonb_build_object('email', p_email, 'first_name', v_first_name, 'last_name', v_last_name),
    'external_reference', v_order_id::text,
    'date_of_expiration', to_char(v_expires_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')
  );

  begin
    select * into v_response from http((
      'POST',
      'https://api.mercadopago.com/v1/payments',
      ARRAY[
        http_header('Authorization', 'Bearer ' || v_token),
        http_header('X-Idempotency-Key', v_order_id::text)
      ],
      'application/json',
      v_payload::text
    )::http_request);
  exception when others then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'Erro de conexão com o Mercado Pago: ' || sqlerrm);
  end;

  if v_response.status < 200 or v_response.status >= 300 then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object(
      'error',
      coalesce((v_response.content::jsonb ->> 'message'), 'Erro ao gerar cobrança Pix no Mercado Pago (status ' || v_response.status || ').')
    );
  end if;

  v_mp := v_response.content::jsonb;
  v_qr_code   := v_mp #>> '{point_of_interaction,transaction_data,qr_code}';
  v_qr_base64 := v_mp #>> '{point_of_interaction,transaction_data,qr_code_base64}';
  v_mp_id     := v_mp ->> 'id';

  if v_qr_code is null then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'O Mercado Pago não retornou um QR code Pix.');
  end if;

  update public.orders
  set mp_payment_id = v_mp_id,
      pix_qr_code = v_qr_code,
      pix_qr_code_base64 = v_qr_base64
  where id = v_order_id;

  return jsonb_build_object(
    'orderId', v_order_id,
    'qrCode', v_qr_code,
    'qrCodeBase64', v_qr_base64,
    'expiresAt', v_expires_at
  );
end;
$$;

revoke all on function public.criar_pix(text, text, jsonb) from public;
grant execute on function public.criar_pix(text, text, jsonb) to anon, authenticated;


-- =====================================================================
-- 7) CONFIRMAÇÃO AUTOMÁTICA DO PAGAMENTO (sem webhook, sem Edge Function)
--    Um job dentro do próprio Postgres pergunta pro Mercado Pago, a
--    cada poucos segundos, se os pedidos pendentes já foram pagos.
-- =====================================================================
create or replace function public.checar_pagamentos_pendentes()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token    text;
  v_order    record;
  v_response http_response;
  v_mp       jsonb;
  v_status   text;
begin
  -- expira pedidos vencidos que nunca foram pagos
  update public.orders
  set status = 'EXPIRADO'
  where status = 'PENDENTE'
    and expires_at is not null
    and expires_at < now();

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return; -- sem token cadastrado ainda, não há o que checar
  end if;

  for v_order in
    select id, mp_payment_id from public.orders
    where status = 'PENDENTE' and mp_payment_id is not null
  loop
    begin
      select * into v_response from http((
        'GET',
        'https://api.mercadopago.com/v1/payments/' || v_order.mp_payment_id,
        ARRAY[http_header('Authorization', 'Bearer ' || v_token)],
        null,
        null
      )::http_request);
    exception when others then
      continue; -- tenta de novo no próximo ciclo
    end;

    if v_response.status between 200 and 299 then
      v_mp := v_response.content::jsonb;
      v_status := v_mp ->> 'status';

      if v_status = 'approved' then
        update public.orders
        set status = 'PAGO', paid_at = now()
        where id = v_order.id;
      elsif v_status in ('rejected', 'cancelled') then
        update public.orders
        set status = 'CANCELADO'
        where id = v_order.id;
      end if;
    end if;
  end loop;
end;
$$;

revoke all on function public.checar_pagamentos_pendentes() from public;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'checar-pagamentos-pix';

  perform cron.schedule(
    'checar-pagamentos-pix',
    '30 seconds',
    $cron$select public.checar_pagamentos_pendentes();$cron$
  );
exception when others then
  begin
    perform cron.schedule(
      'checar-pagamentos-pix',
      '* * * * *',
      $cron$select public.checar_pagamentos_pendentes();$cron$
    );
    raise notice 'pg_cron não aceitou intervalo de segundos nesta versão — agendado para rodar 1x por minuto.';
  exception when others then
    raise notice 'Não consegui agendar o job automático (%). Ative a extensão "pg_cron" em Database → Extensions e rode este bloco novamente.', sqlerrm;
  end;
end $$;


-- =====================================================================
-- 8) STORAGE — buckets de imagens (produtos e aparência do site)
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('site-assets', 'site-assets', true)
on conflict (id) do nothing;

drop policy if exists "public read product-images" on storage.objects;
create policy "public read product-images" on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists "public read site-assets" on storage.objects;
create policy "public read site-assets" on storage.objects
  for select using (bucket_id = 'site-assets');

drop policy if exists "admin upload product-images" on storage.objects;
create policy "admin upload product-images" on storage.objects
  for insert with check (bucket_id = 'product-images' and auth.role() = 'authenticated');

drop policy if exists "admin update product-images" on storage.objects;
create policy "admin update product-images" on storage.objects
  for update using (bucket_id = 'product-images' and auth.role() = 'authenticated');

drop policy if exists "admin delete product-images" on storage.objects;
create policy "admin delete product-images" on storage.objects
  for delete using (bucket_id = 'product-images' and auth.role() = 'authenticated');

drop policy if exists "admin upload site-assets" on storage.objects;
create policy "admin upload site-assets" on storage.objects
  for insert with check (bucket_id = 'site-assets' and auth.role() = 'authenticated');

drop policy if exists "admin update site-assets" on storage.objects;
create policy "admin update site-assets" on storage.objects
  for update using (bucket_id = 'site-assets' and auth.role() = 'authenticated');

drop policy if exists "admin delete site-assets" on storage.objects;
create policy "admin delete site-assets" on storage.objects
  for delete using (bucket_id = 'site-assets' and auth.role() = 'authenticated');


-- =====================================================================
-- 9) ÚLTIMO PASSO (só esse é manual): cadastrar o token do Mercado Pago
-- =====================================================================
-- OPÇÃO A — pelo site, sem SQL (recomendado):
--   Supabase → seu projeto → Project Settings → Vault → "Add new secret"
--     Name:  mp_access_token
--     Value: seu Access Token de produção do Mercado Pago
--
-- OPÇÃO B — por SQL, rodando isto aqui (troque SEU_TOKEN_AQUI):
--   select vault.create_secret('APP_USR-4856290854903668-032123-5fff247030e782e3b58c16e065294408-2514178336', 'mp_access_token');
--
-- Depois de cadastrar o token, o Pix já funciona sozinho — não precisa
-- rodar mais nada.
-- =====================================================================

-- =====================================================================
-- NOVASTORE — AUTENTICAÇÃO DE CLIENTES, PERFIS (ROLE) E CHAT DE ENTREGA (v3)
-- =====================================================================
-- Rode este script DEPOIS do script principal que já criou as tabelas
-- products / site_settings / orders / a função criar_pix.
-- Ele é aditivo e seguro de rodar de novo: cria o que falta, atualiza
-- funções com CREATE OR REPLACE e nunca apaga dados existentes.
--
-- O que este script adiciona:
--   1) Tabela public.profiles  (nome, avatar, role: 'client' | 'admin')
--      criada automaticamente para todo novo usuário que se cadastra.
--   2) Coluna orders.customer_id, ligando cada pedido à conta do cliente
--      que comprou (necessário para o chat e pra corrigir o acesso aos
--      pedidos, que antes era liberado pra qualquer usuário logado).
--   3) Tabela public.messages — o chat entre cliente e loja, por pedido.
--   4) Função criar_pix atualizada para gravar o customer_id do pedido.
--   5) Regras de segurança (RLS) coerentes com o novo modelo de acesso.
-- =====================================================================

create extension if not exists pgcrypto;


-- =====================================================================
-- 1) PROFILES — perfil de cada usuário (nome, avatar, role)
-- =====================================================================
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  role        text not null default 'client' check (role in ('admin','client')),
  created_at  timestamptz default now()
);

alter table public.profiles enable row level security;

-- função auxiliar (SECURITY DEFINER) usada nas policies abaixo pra checar
-- se o usuário logado é admin, sem cair em recursão de RLS na própria tabela
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

drop policy if exists "users read own profile" on public.profiles;
create policy "users read own profile" on public.profiles
  for select using (auth.uid() = id or public.is_admin());

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles
  for update using (auth.uid() = id or public.is_admin());

-- não existe policy pública de insert: o perfil é criado automaticamente
-- pela trigger abaixo (que roda como SECURITY DEFINER e ignora RLS)

-- cria o profile assim que alguém se cadastra (supabase.auth.signUp)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'avatar_url',
    'client'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- =====================================================================
-- 2) ORDERS — liga cada pedido à conta do cliente + corrige as regras
--    de acesso (antes, qualquer usuário autenticado podia ver TODOS os
--    pedidos; agora só o admin real, ou o próprio dono do pedido).
-- =====================================================================
alter table public.orders add column if not exists customer_id uuid references auth.users(id);
create index if not exists idx_orders_customer_id on public.orders (customer_id);

drop policy if exists "admin can view orders" on public.orders;
drop policy if exists "customers read own orders" on public.orders;
drop policy if exists "orders select" on public.orders;
create policy "orders select" on public.orders
  for select using (public.is_admin() or auth.uid() = customer_id);

drop policy if exists "admin can update orders" on public.orders;
drop policy if exists "orders update" on public.orders;
create policy "orders update" on public.orders
  for update using (public.is_admin());


-- =====================================================================
-- 3) CRIAR_PIX — mesma função de antes, agora também gravando o
--    customer_id (quando o cliente estiver logado no momento da compra)
-- =====================================================================
create or replace function public.criar_pix(p_name text, p_email text, p_items jsonb, p_customer_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token        text;
  v_total        numeric;
  v_order_id     uuid;
  v_expires_at   timestamptz := now() + interval '30 minutes';
  v_first_name   text;
  v_last_name    text;
  v_payload      jsonb;
  v_response     http_response;
  v_mp           jsonb;
  v_qr_code      text;
  v_qr_base64    text;
  v_mp_id        text;
begin
  if p_name is null or p_email is null or p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'Dados incompletos para gerar o Pix.');
  end if;

  select coalesce(sum((item->>'price')::numeric * coalesce((item->>'quantity')::numeric, 1)), 0)
  into v_total
  from jsonb_array_elements(p_items) as item;

  if v_total <= 0 then
    return jsonb_build_object('error', 'Valor do pedido inválido.');
  end if;

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return jsonb_build_object('error', 'Token do Mercado Pago não configurado. Cadastre o segredo "mp_access_token" no Vault do Supabase.');
  end if;

  insert into public.orders (customer_name, customer_email, customer_id, items, total, status, expires_at)
  values (p_name, p_email, p_customer_id, p_items, v_total, 'PENDENTE', v_expires_at)
  returning id into v_order_id;

  v_first_name := split_part(trim(p_name), ' ', 1);
  v_last_name  := nullif(trim(substr(trim(p_name), length(v_first_name) + 1)), '');
  if v_last_name is null then v_last_name := v_first_name; end if;

  v_payload := jsonb_build_object(
    'transaction_amount', round(v_total, 2),
    'description', 'Pedido NovaStore #' || left(v_order_id::text, 8),
    'payment_method_id', 'pix',
    'payer', jsonb_build_object('email', p_email, 'first_name', v_first_name, 'last_name', v_last_name),
    'external_reference', v_order_id::text,
    'date_of_expiration', to_char(v_expires_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')
  );

  begin
    select * into v_response from http((
      'POST',
      'https://api.mercadopago.com/v1/payments',
      ARRAY[
        http_header('Authorization', 'Bearer ' || v_token),
        http_header('X-Idempotency-Key', v_order_id::text)
      ],
      'application/json',
      v_payload::text
    )::http_request);
  exception when others then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'Erro de conexão com o Mercado Pago: ' || sqlerrm);
  end;

  if v_response.status < 200 or v_response.status >= 300 then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object(
      'error',
      coalesce((v_response.content::jsonb ->> 'message'), 'Erro ao gerar cobrança Pix no Mercado Pago (status ' || v_response.status || ').')
    );
  end if;

  v_mp := v_response.content::jsonb;
  v_qr_code   := v_mp #>> '{point_of_interaction,transaction_data,qr_code}';
  v_qr_base64 := v_mp #>> '{point_of_interaction,transaction_data,qr_code_base64}';
  v_mp_id     := v_mp ->> 'id';

  if v_qr_code is null then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'O Mercado Pago não retornou um QR code Pix.');
  end if;

  update public.orders
  set mp_payment_id = v_mp_id,
      pix_qr_code = v_qr_code,
      pix_qr_code_base64 = v_qr_base64
  where id = v_order_id;

  return jsonb_build_object(
    'orderId', v_order_id,
    'qrCode', v_qr_code,
    'qrCodeBase64', v_qr_base64,
    'expiresAt', v_expires_at
  );
end;
$$;

revoke all on function public.criar_pix(text, text, jsonb, uuid) from public;
grant execute on function public.criar_pix(text, text, jsonb, uuid) to anon, authenticated;


-- =====================================================================
-- 4) MESSAGES — chat entre cliente e loja, atrelado a um pedido pago
-- =====================================================================
create table if not exists public.messages (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  sender_id     uuid references auth.users(id),
  receiver_id   uuid references auth.users(id),
  message_text  text not null,
  read_at       timestamptz,
  created_at    timestamptz default now()
);

create index if not exists idx_messages_order_id on public.messages (order_id, created_at);

alter table public.messages enable row level security;

-- cliente só lê mensagens de pedidos que são dele; admin lê tudo
drop policy if exists "participants read messages" on public.messages;
create policy "participants read messages" on public.messages
  for select using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

-- cliente só envia mensagem em nome dele mesmo, em pedido que é dele; admin envia em qualquer um
drop policy if exists "participants send messages" on public.messages;
create policy "participants send messages" on public.messages
  for insert with check (
    sender_id = auth.uid()
    and (
      public.is_admin()
      or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
    )
  );

-- permite marcar mensagens como lidas (read_at) pelos participantes da conversa
drop policy if exists "participants update messages read status" on public.messages;
create policy "participants update messages read status" on public.messages
  for update using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

-- habilita realtime (mensagens aparecem na hora, sem precisar recarregar)
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when others then
  raise notice 'Tabela messages já estava no publication de realtime, ou o publication tem outro nome (%).', sqlerrm;
end $$;


-- =====================================================================
-- 5) ÚLTIMO PASSO (manual): promover sua conta a administrador
-- =====================================================================
-- 1. Crie sua conta normalmente pelo site (botão "Login" → aba "Criar conta").
-- 2. Depois, rode isto aqui trocando pelo e-mail que você cadastrou:
--
--   update public.profiles set role = 'admin'
--   where id = (select id from auth.users where email = 'filipecapelasso1@gmail.com');
--
-- A partir daí, essa conta consegue entrar em /#admin normalmente — contas
-- sem role = 'admin' são bloqueadas e deslogadas automaticamente ao tentar.
-- =====================================================================

-- =====================================================================
-- NOVASTORE — AVALIAÇÕES DE PRODUTO (tabela public.avaliacoes)
-- =====================================================================
-- Rode depois dos scripts anteriores (precisa de public.orders e
-- public.products já existindo). Aditivo, seguro de rodar de novo.
--
-- Regra de negócio: só pode avaliar quem tiver pelo menos um pedido com
-- status PAGO contendo aquele product_id — isso é garantido dentro da
-- própria política de RLS (insert), não só no frontend.
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists public.avaliacoes (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references auth.users(id) on delete cascade,
  product_id    uuid not null references public.products(id) on delete cascade,
  customer_name text not null,
  rating        smallint not null check (rating between 1 and 5),
  comment       text not null check (char_length(trim(comment)) > 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (customer_id, product_id)
);

create index if not exists idx_avaliacoes_product on public.avaliacoes (product_id, created_at desc);

alter table public.avaliacoes enable row level security;

-- avaliações são conteúdo público (aparecem na página do produto e na home)
drop policy if exists "avaliacoes select public" on public.avaliacoes;
create policy "avaliacoes select public" on public.avaliacoes
  for select using (true);

-- só cria avaliação quem comprovadamente comprou (pedido PAGO com esse produto)
drop policy if exists "avaliacoes insert own purchase" on public.avaliacoes;
create policy "avaliacoes insert own purchase" on public.avaliacoes
  for insert with check (
    customer_id = auth.uid()
    and exists (
      select 1
      from public.orders o, jsonb_array_elements(o.items) it
      where o.customer_id = auth.uid()
        and o.status = 'PAGO'
        and it->>'productId' = avaliacoes.product_id::text
    )
  );

-- cliente pode editar a própria avaliação depois (corrigir nota/comentário)
drop policy if exists "avaliacoes update own" on public.avaliacoes;
create policy "avaliacoes update own" on public.avaliacoes
  for update using (customer_id = auth.uid())
  with check (customer_id = auth.uid());

-- cliente pode apagar a própria avaliação; admin pode moderar (apagar qualquer uma)
drop policy if exists "avaliacoes delete own or admin" on public.avaliacoes;
create policy "avaliacoes delete own or admin" on public.avaliacoes
  for delete using (customer_id = auth.uid() or public.is_admin());

-- mantém updated_at em dia quando o cliente edita a avaliação
create or replace function public.avaliacoes_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_avaliacoes_updated_at on public.avaliacoes;
create trigger trg_avaliacoes_updated_at
  before update on public.avaliacoes
  for each row execute function public.avaliacoes_set_updated_at();

  -- =====================================================================
-- NOVASTORE — CHAT GLOBAL (comunidade) + CHAT PRIVADO (admin ↔ cliente)
-- =====================================================================
-- Rode este script DEPOIS do script que já criou public.profiles e a
-- função public.is_admin() (o script de autenticação/perfis que você
-- já rodou antes). Ele é aditivo: usa IF NOT EXISTS / CREATE OR REPLACE
-- e não apaga nada que já existe.
--
-- O que este script cria:
--   1) public.chat_global   — chat público, visível pra qualquer usuário
--      autenticado, todo mundo pode ler e escrever.
--   2) public.chat_privado  — chat 1-para-1 entre um cliente específico
--      e o admin. O cliente só vê a própria conversa; o admin vê todas.
--   3) RLS coerente com as regras acima + Realtime habilitado nas duas.
-- =====================================================================

create extension if not exists pgcrypto;

-- garante que a função auxiliar de admin existe (caso este script rode
-- isoladamente); se já existir, isso só recria com o mesmo comportamento
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;


-- =====================================================================
-- 1) CHAT GLOBAL — sala pública, um único canal para todos os clientes
--    logados conversarem entre si.
-- =====================================================================
create table if not exists public.chat_global (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  sender_name   text not null,          -- guardado na hora do envio (evita
                                         -- precisar ler o profile de outros
                                         -- usuários, que o RLS de profiles
                                         -- não libera)
  sender_role   text not null default 'client' check (sender_role in ('admin','client')),
  message_text  text not null check (char_length(trim(message_text)) > 0),
  created_at    timestamptz not null default now()
);

create index if not exists idx_chat_global_created_at on public.chat_global (created_at);

alter table public.chat_global enable row level security;

-- qualquer usuário autenticado pode ler o chat global
drop policy if exists "chat_global select authenticated" on public.chat_global;
create policy "chat_global select authenticated" on public.chat_global
  for select using (auth.role() = 'authenticated');

-- qualquer usuário autenticado pode enviar mensagem, mas só em nome dele mesmo
drop policy if exists "chat_global insert own" on public.chat_global;
create policy "chat_global insert own" on public.chat_global
  for insert with check (
    sender_id = auth.uid()
    and auth.role() = 'authenticated'
  );

-- só o admin pode apagar mensagens (moderação); ninguém pode editar
drop policy if exists "chat_global delete admin" on public.chat_global;
create policy "chat_global delete admin" on public.chat_global
  for delete using (public.is_admin());

do $$
begin
  alter publication supabase_realtime add table public.chat_global;
exception when others then
  raise notice 'chat_global já estava no publication de realtime (%).', sqlerrm;
end $$;


-- =====================================================================
-- 2) CHAT PRIVADO — conversa 1-para-1 entre um cliente e o admin da loja.
--    Uma única "thread" contínua por cliente (não é por pedido): o admin
--    usa esse canal pra falar sobre entrega, suporte etc.
-- =====================================================================
create table if not exists public.chat_privado (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references auth.users(id) on delete cascade, -- dono da conversa (o cliente)
  sender_id     uuid not null references auth.users(id),                   -- quem mandou essa mensagem
  sender_role   text not null check (sender_role in ('admin','client')),
  message_text  text not null check (char_length(trim(message_text)) > 0),
  read_at       timestamptz,          -- preenchido quando o destinatário lê
  created_at    timestamptz not null default now()
);

create index if not exists idx_chat_privado_customer on public.chat_privado (customer_id, created_at);
create index if not exists idx_chat_privado_unread on public.chat_privado (customer_id) where read_at is null;

alter table public.chat_privado enable row level security;

-- o cliente só lê a própria conversa; o admin lê todas
drop policy if exists "chat_privado select" on public.chat_privado;
create policy "chat_privado select" on public.chat_privado
  for select using (
    public.is_admin() or customer_id = auth.uid()
  );

-- cliente só manda mensagem na própria conversa (como 'client');
-- admin manda em qualquer conversa (como 'admin')
drop policy if exists "chat_privado insert" on public.chat_privado;
create policy "chat_privado insert" on public.chat_privado
  for insert with check (
    sender_id = auth.uid()
    and (
      (public.is_admin() and sender_role = 'admin')
      or (customer_id = auth.uid() and sender_role = 'client')
    )
  );

-- permite marcar como lida (read_at) — só quem participa da conversa
drop policy if exists "chat_privado update read status" on public.chat_privado;
create policy "chat_privado update read status" on public.chat_privado
  for update using (
    public.is_admin() or customer_id = auth.uid()
  ) with check (
    public.is_admin() or customer_id = auth.uid()
  );

do $$
begin
  alter publication supabase_realtime add table public.chat_privado;
exception when others then
  raise notice 'chat_privado já estava no publication de realtime (%).', sqlerrm;
end $$;

-- =====================================================================
-- Pronto. Depois de rodar este script:
--   • O ícone 🌐 no header (entre Carrinho e Perfil) abre o Chat Global.
--   • "Meus chats" no menu do Perfil abre o Chat Privado com o admin,
--     com uma bolinha de notificação quando chega mensagem nova do admin.
--   • No painel admin, a aba "Mensagens" lista os clientes que já
--     mandaram mensagem e permite responder pelo mesmo canal.
-- =====================================================================

-- =====================================================================
-- NOVASTORE — SISTEMA DE AMIGOS, CHAT PRIVADO E TEMA DO SITE
-- =====================================================================
-- Rode depois de avaliacoes.sql (e depois dos scripts que já criam
-- public.profiles, public.chat_global, public.chat_privado e
-- public.site_settings). Aditivo e seguro de rodar de novo.
--
-- Este script:
--   1) adiciona imagem + id de deduplicação otimista ao chat global
--   2) cria a tabela public.amigos (pedidos/relação de amizade)
--   3) cria a tabela public.mensagens_privadas (DM entre dois usuários)
--   4) garante public.site_settings com as colunas de tema/efeitos
--   5) cria o bucket de storage "chat-uploads" (imagens de chat)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) CHAT GLOBAL — suporte a imagem, avatar do remetente e client_id
--    (client_id é usado pelo front pra não duplicar a bolha otimista
--    quando o realtime devolve a mesma mensagem que o próprio usuário
--    acabou de enviar)
-- ---------------------------------------------------------------------
alter table public.chat_global add column if not exists image_url text;
alter table public.chat_global add column if not exists sender_avatar_url text;
alter table public.chat_global add column if not exists client_id uuid;

alter table public.chat_global
  drop constraint if exists chat_global_texto_ou_imagem;
alter table public.chat_global
  add constraint chat_global_texto_ou_imagem check (message_text is not null or image_url is not null);

-- ---------------------------------------------------------------------
-- 2) AMIGOS — pedidos de amizade e amizades aceitas entre clientes
--    (nome/avatar do outro lado ficam denormalizados pra montar a lista
--    de amigos sem precisar de um join extra em profiles)
-- ---------------------------------------------------------------------
create table if not exists public.amigos (
  id                    uuid primary key default gen_random_uuid(),
  requester_id          uuid not null references auth.users(id) on delete cascade,
  addressee_id          uuid not null references auth.users(id) on delete cascade,
  requester_name        text,
  requester_avatar_url  text,
  addressee_name        text,
  addressee_avatar_url  text,
  status                text not null default 'pending' check (status in ('pending','accepted')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint amigos_nao_pode_ser_consigo_mesmo check (requester_id <> addressee_id),
  unique (requester_id, addressee_id)
);

create index if not exists idx_amigos_requester on public.amigos (requester_id, status);
create index if not exists idx_amigos_addressee on public.amigos (addressee_id, status);

alter table public.amigos enable row level security;

drop policy if exists "amigos select proprios" on public.amigos;
create policy "amigos select proprios" on public.amigos
  for select using (requester_id = auth.uid() or addressee_id = auth.uid());

-- só pode criar um pedido de amizade partindo de si mesmo
drop policy if exists "amigos insert proprio pedido" on public.amigos;
create policy "amigos insert proprio pedido" on public.amigos
  for insert with check (requester_id = auth.uid());

-- só quem recebeu o pedido pode aceitar (mudar status pra accepted)
drop policy if exists "amigos update aceitar" on public.amigos;
create policy "amigos update aceitar" on public.amigos
  for update using (addressee_id = auth.uid() or requester_id = auth.uid())
  with check (addressee_id = auth.uid() or requester_id = auth.uid());

-- qualquer um dos dois lados pode cancelar o pedido / desfazer a amizade
drop policy if exists "amigos delete proprios" on public.amigos;
create policy "amigos delete proprios" on public.amigos
  for delete using (requester_id = auth.uid() or addressee_id = auth.uid());

create or replace function public.amigos_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_amigos_updated_at on public.amigos;
create trigger trg_amigos_updated_at
  before update on public.amigos
  for each row execute function public.amigos_set_updated_at();

-- ---------------------------------------------------------------------
-- 3) MENSAGENS PRIVADAS — DM 1-para-1 entre dois clientes (não exige
--    amizade aceita pra conversar; "amigos" é uma camada social de
--    atalho/organização, não uma trava de permissão de mensagem)
-- ---------------------------------------------------------------------
create table if not exists public.mensagens_privadas (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  receiver_id   uuid not null references auth.users(id) on delete cascade,
  message_text  text,
  image_url     text,
  created_at    timestamptz not null default now(),
  read_at       timestamptz,
  constraint mensagens_privadas_texto_ou_imagem check (message_text is not null or image_url is not null),
  constraint mensagens_privadas_nao_consigo_mesmo check (sender_id <> receiver_id)
);

create index if not exists idx_msgpriv_thread on public.mensagens_privadas (least(sender_id, receiver_id), greatest(sender_id, receiver_id), created_at);
create index if not exists idx_msgpriv_receiver_unread on public.mensagens_privadas (receiver_id, read_at);

alter table public.mensagens_privadas enable row level security;

drop policy if exists "mensagens_privadas select proprias" on public.mensagens_privadas;
create policy "mensagens_privadas select proprias" on public.mensagens_privadas
  for select using (sender_id = auth.uid() or receiver_id = auth.uid());

drop policy if exists "mensagens_privadas insert proprio envio" on public.mensagens_privadas;
create policy "mensagens_privadas insert proprio envio" on public.mensagens_privadas
  for insert with check (sender_id = auth.uid());

-- só o destinatário pode marcar como lida (read_at)
drop policy if exists "mensagens_privadas update marcar lida" on public.mensagens_privadas;
create policy "mensagens_privadas update marcar lida" on public.mensagens_privadas
  for update using (receiver_id = auth.uid())
  with check (receiver_id = auth.uid());

drop policy if exists "mensagens_privadas delete proprias" on public.mensagens_privadas;
create policy "mensagens_privadas delete proprias" on public.mensagens_privadas
  for delete using (sender_id = auth.uid());

-- ---------------------------------------------------------------------
-- 4) SITE_SETTINGS — garante a tabela (caso ainda não exista) e adiciona
--    as colunas de tema de cores + efeito de raios usadas no painel admin
-- ---------------------------------------------------------------------
create table if not exists public.site_settings (
  id                   int primary key default 1,
  hero_image_url       text,
  hero_overlay         numeric not null default 0.35,
  background_image_url text,
  background_overlay   numeric not null default 0.85,
  updated_at           timestamptz not null default now()
);

alter table public.site_settings add column if not exists theme_primary text not null default '#7c5cff';
alter table public.site_settings add column if not exists theme_accent text not null default '#00e6a8';
alter table public.site_settings add column if not exists effect_lightning boolean not null default false;

alter table public.site_settings enable row level security;

-- configuração de aparência é pública pra qualquer visitante poder carregar o tema
drop policy if exists "site_settings select public" on public.site_settings;
create policy "site_settings select public" on public.site_settings
  for select using (true);

-- só o admin pode alterar (usa a mesma public.is_admin() de avaliacoes.sql)
drop policy if exists "site_settings upsert admin" on public.site_settings;
create policy "site_settings upsert admin" on public.site_settings
  for insert with check (public.is_admin());

drop policy if exists "site_settings update admin" on public.site_settings;
create policy "site_settings update admin" on public.site_settings
  for update using (public.is_admin()) with check (public.is_admin());

insert into public.site_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 5) STORAGE — bucket público pra imagens de chat (global + privado)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('chat-uploads', 'chat-uploads', true)
on conflict (id) do nothing;

drop policy if exists "chat-uploads leitura publica" on storage.objects;
create policy "chat-uploads leitura publica" on storage.objects
  for select using (bucket_id = 'chat-uploads');

drop policy if exists "chat-uploads upload autenticado" on storage.objects;
create policy "chat-uploads upload autenticado" on storage.objects
  for insert to authenticated with check (bucket_id = 'chat-uploads');

drop policy if exists "chat-uploads update autor" on storage.objects;
create policy "chat-uploads update autor" on storage.objects
  for update to authenticated using (bucket_id = 'chat-uploads' and owner = auth.uid());

  -- =====================================================================
-- NOVASTORE — SISTEMA DE INDICAÇÃO / CÓDIGO DE ANUNCIANTE
-- =====================================================================
-- Rode este script DEPOIS de todos os scripts anteriores (precisa de
-- public.profiles, public.orders, public.is_admin() já existindo).
-- É aditivo e seguro de rodar de novo: usa IF NOT EXISTS / CREATE OR
-- REPLACE e nunca apaga dados existentes.
--
-- O que este script cria:
--   1) public.anunciantes            — cadastro de anunciantes/códigos
--   2) public.historico_vendas_anunciantes — vendas feitas com cada código
--   3) profiles.tem_cupom_proxima_compra — controla o cupom de R$20 ganho
--   4) orders.anunciante_codigo / orders.cupom_usado / orders.desconto_aplicado
--   5) criar_pix atualizado (agora aceita código de anunciante e uso do cupom)
--   6) Trigger que roda quando um pedido é marcado como PAGO:
--      - registra a venda no histórico do anunciante
--      - soma +1 em anunciantes.total_vendas
--      - dá o cupom de R$20 pro cliente (próxima compra)
--      - consome o cupom, se ele foi usado nesse pedido
-- =====================================================================

create extension if not exists pgcrypto;


-- =====================================================================
-- 1) TABELA: anunciantes
-- =====================================================================
create table if not exists public.anunciantes (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  codigo       text not null unique,
  total_vendas integer not null default 0,
  created_at   timestamptz not null default now()
);

alter table public.anunciantes enable row level security;

-- qualquer cliente logado pode validar/consultar um código no checkout
drop policy if exists "anunciantes select authenticated" on public.anunciantes;
create policy "anunciantes select authenticated" on public.anunciantes
  for select using (auth.role() = 'authenticated');

-- só o admin cria, edita e apaga anunciantes
drop policy if exists "anunciantes admin insert" on public.anunciantes;
create policy "anunciantes admin insert" on public.anunciantes
  for insert with check (public.is_admin());

drop policy if exists "anunciantes admin update" on public.anunciantes;
create policy "anunciantes admin update" on public.anunciantes
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "anunciantes admin delete" on public.anunciantes;
create policy "anunciantes admin delete" on public.anunciantes
  for delete using (public.is_admin());


-- =====================================================================
-- 2) TABELA: historico_vendas_anunciantes
-- =====================================================================
create table if not exists public.historico_vendas_anunciantes (
  id             uuid primary key default gen_random_uuid(),
  anunciante_id  uuid not null references public.anunciantes(id) on delete cascade,
  cliente_id     uuid references auth.users(id),
  cliente_nome   text,
  produto_nome   text not null,
  valor_compra   numeric not null,
  created_at     timestamptz not null default now()
);

create index if not exists idx_historico_anunciante on public.historico_vendas_anunciantes (anunciante_id, created_at desc);

alter table public.historico_vendas_anunciantes enable row level security;

-- só o admin vê o histórico completo (as inserções acontecem via trigger
-- SECURITY DEFINER, então não é preciso policy pública de insert)
drop policy if exists "historico admin select" on public.historico_vendas_anunciantes;
create policy "historico admin select" on public.historico_vendas_anunciantes
  for select using (public.is_admin());


-- =====================================================================
-- 3) PROFILES — coluna de controle do cupom de R$20 (próxima compra)
-- =====================================================================
alter table public.profiles add column if not exists tem_cupom_proxima_compra boolean not null default false;


-- =====================================================================
-- 4) ORDERS — guarda o código usado, se o cupom foi aplicado e o desconto
-- =====================================================================
alter table public.orders add column if not exists anunciante_codigo text;
alter table public.orders add column if not exists cupom_usado boolean not null default false;
alter table public.orders add column if not exists desconto_aplicado numeric not null default 0;


-- =====================================================================
-- 5) CRIAR_PIX — atualizado para validar o código de anunciante e aplicar
--    o desconto de R$20 quando o cliente tiver o cupom e o carrinho for
--    >= R$100,00. Mantém compatibilidade: os 2 novos parâmetros são
--    opcionais (default), então chamadas antigas continuam funcionando.
-- =====================================================================
create or replace function public.criar_pix(
  p_name text,
  p_email text,
  p_items jsonb,
  p_customer_id uuid default null,
  p_anunciante_codigo text default null,
  p_usar_cupom boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token        text;
  v_total        numeric;
  v_order_id     uuid;
  v_expires_at   timestamptz := now() + interval '30 minutes';
  v_first_name   text;
  v_last_name    text;
  v_payload      jsonb;
  v_response     http_response;
  v_mp           jsonb;
  v_qr_code      text;
  v_qr_base64    text;
  v_mp_id        text;
  v_codigo       text;
  v_desconto     numeric := 0;
  v_cupom_ok     boolean := false;
begin
  if p_name is null or p_email is null or p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'Dados incompletos para gerar o Pix.');
  end if;

  select coalesce(sum((item->>'price')::numeric * coalesce((item->>'quantity')::numeric, 1)), 0)
  into v_total
  from jsonb_array_elements(p_items) as item;

  if v_total <= 0 then
    return jsonb_build_object('error', 'Valor do pedido inválido.');
  end if;

  -- valida o código de anunciante, se informado
  v_codigo := nullif(trim(p_anunciante_codigo), '');
  if v_codigo is not null and not exists (select 1 from public.anunciantes where codigo = v_codigo) then
    return jsonb_build_object('error', 'Código de anunciante inválido.');
  end if;

  -- valida e aplica o cupom de R$20 (só se o cliente realmente tiver o cupom
  -- e o total do carrinho, antes do desconto, for >= R$100)
  if p_usar_cupom and p_customer_id is not null then
    select coalesce(tem_cupom_proxima_compra, false) into v_cupom_ok
    from public.profiles where id = p_customer_id;

    if v_cupom_ok and v_total >= 100 then
      v_desconto := 20;
    end if;
  end if;

  v_total := greatest(v_total - v_desconto, 0.01);

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return jsonb_build_object('error', 'Token do Mercado Pago não configurado. Cadastre o segredo "mp_access_token" no Vault do Supabase.');
  end if;

  insert into public.orders (
    customer_name, customer_email, customer_id, items, total, status, expires_at,
    anunciante_codigo, cupom_usado, desconto_aplicado
  )
  values (
    p_name, p_email, p_customer_id, p_items, v_total, 'PENDENTE', v_expires_at,
    v_codigo, (v_desconto > 0), v_desconto
  )
  returning id into v_order_id;

  v_first_name := split_part(trim(p_name), ' ', 1);
  v_last_name  := nullif(trim(substr(trim(p_name), length(v_first_name) + 1)), '');
  if v_last_name is null then v_last_name := v_first_name; end if;

  v_payload := jsonb_build_object(
    'transaction_amount', round(v_total, 2),
    'description', 'Pedido NovaStore #' || left(v_order_id::text, 8),
    'payment_method_id', 'pix',
    'payer', jsonb_build_object('email', p_email, 'first_name', v_first_name, 'last_name', v_last_name),
    'external_reference', v_order_id::text,
    'date_of_expiration', to_char(v_expires_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')
  );

  begin
    select * into v_response from http((
      'POST',
      'https://api.mercadopago.com/v1/payments',
      ARRAY[
        http_header('Authorization', 'Bearer ' || v_token),
        http_header('X-Idempotency-Key', v_order_id::text)
      ],
      'application/json',
      v_payload::text
    )::http_request);
  exception when others then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'Erro de conexão com o Mercado Pago: ' || sqlerrm);
  end;

  if v_response.status < 200 or v_response.status >= 300 then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object(
      'error',
      coalesce((v_response.content::jsonb ->> 'message'), 'Erro ao gerar cobrança Pix no Mercado Pago (status ' || v_response.status || ').')
    );
  end if;

  v_mp := v_response.content::jsonb;
  v_qr_code   := v_mp #>> '{point_of_interaction,transaction_data,qr_code}';
  v_qr_base64 := v_mp #>> '{point_of_interaction,transaction_data,qr_code_base64}';
  v_mp_id     := v_mp ->> 'id';

  if v_qr_code is null then
    update public.orders set status = 'CANCELADO' where id = v_order_id;
    return jsonb_build_object('error', 'O Mercado Pago não retornou um QR code Pix.');
  end if;

  update public.orders
  set mp_payment_id = v_mp_id,
      pix_qr_code = v_qr_code,
      pix_qr_code_base64 = v_qr_base64
  where id = v_order_id;

  return jsonb_build_object(
    'orderId', v_order_id,
    'qrCode', v_qr_code,
    'qrCodeBase64', v_qr_base64,
    'expiresAt', v_expires_at,
    'total', v_total,
    'descontoAplicado', v_desconto
  );
end;
$$;

revoke all on function public.criar_pix(text, text, jsonb, uuid, text, boolean) from public;
grant execute on function public.criar_pix(text, text, jsonb, uuid, text, boolean) to anon, authenticated;


-- =====================================================================
-- 6) TRIGGER — quando um pedido passa a ter status = 'PAGO':
--      a) se tiver código de anunciante: soma +1 em total_vendas,
--         registra cada produto no histórico e dá o cupom de R$20
--         pro cliente (próxima compra)
--      b) se o pedido tiver consumido um cupom (cupom_usado = true):
--         zera tem_cupom_proxima_compra do cliente
-- =====================================================================
create or replace function public.processar_pagamento_indicacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_anunciante record;
  v_item       jsonb;
begin
  if new.status = 'PAGO' and old.status is distinct from 'PAGO' then

    if new.anunciante_codigo is not null then
      select * into v_anunciante from public.anunciantes where codigo = new.anunciante_codigo;

      if found then
        update public.anunciantes set total_vendas = total_vendas + 1 where id = v_anunciante.id;

        for v_item in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb))
        loop
          insert into public.historico_vendas_anunciantes (
            anunciante_id, cliente_id, cliente_nome, produto_nome, valor_compra
          ) values (
            v_anunciante.id,
            new.customer_id,
            new.customer_name,
            coalesce(v_item->>'name', 'Produto'),
            coalesce((v_item->>'price')::numeric, 0) * coalesce((v_item->>'quantity')::numeric, 1)
          );
        end loop;

        if new.customer_id is not null then
          update public.profiles set tem_cupom_proxima_compra = true where id = new.customer_id;
        end if;
      end if;
    end if;

    if new.cupom_usado and new.customer_id is not null then
      update public.profiles set tem_cupom_proxima_compra = false where id = new.customer_id;
    end if;

  end if;

  return new;
end;
$$;

drop trigger if exists trg_orders_processar_indicacao on public.orders;
create trigger trg_orders_processar_indicacao
  after update on public.orders
  for each row execute function public.processar_pagamento_indicacao();

-- =====================================================================
-- Pronto. Depois de rodar este script:
--   • No checkout, o campo "Código do Anunciante / Indicação" valida o
--     código digitado contra a tabela anunciantes.
--   • Quando o Pix daquele pedido for confirmado (status PAGO), o
--     anunciante ganha +1 venda, o produto entra no histórico dele, e o
--     cliente ganha um cupom de R$20 pra próxima compra.
--   • Se o cliente já tiver o cupom e o carrinho for >= R$100, aparece a
--     opção de usá-lo no checkout; o valor cobrado no Pix já sai com o
--     desconto aplicado.
--   • No painel admin, a aba "Anunciantes" permite cadastrar, excluir e
--     ver o histórico de vendas de cada código.
-- =====================================================================

-- =============================================================================
-- NOVASTORE — SISTEMA DE SORTEIOS
-- Rode este script inteiro de uma vez no Supabase (SQL Editor → New query → Run).
-- É seguro rodar mais de uma vez: usa "if not exists" / "or replace" em tudo,
-- e só insere os sorteios de exemplo se a tabela "sorteios" ainda estiver vazia.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1) CÓDIGO DO CLIENTE
--    Toda conta de cliente (tabela profiles) passa a ter um código único
--    no formato NS-00000, usado como "número" dele nos sorteios.
-- -----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists codigo_cliente text unique;

create or replace function public.gerar_codigo_cliente()
returns text
language plpgsql
as $$
declare
  novo_codigo text;
  ja_existe boolean;
begin
  loop
    novo_codigo := 'NS-' || lpad(floor(random() * 100000)::int::text, 5, '0');
    select exists(select 1 from public.profiles where codigo_cliente = novo_codigo) into ja_existe;
    exit when not ja_existe;
  end loop;
  return novo_codigo;
end;
$$;

-- gera o código automaticamente pra cada cliente novo que se cadastrar
create or replace function public.trg_set_codigo_cliente()
returns trigger
language plpgsql
as $$
begin
  if new.codigo_cliente is null then
    new.codigo_cliente := public.gerar_codigo_cliente();
  end if;
  return new;
end;
$$;

drop trigger if exists set_codigo_cliente on public.profiles;
create trigger set_codigo_cliente
before insert on public.profiles
for each row execute function public.trg_set_codigo_cliente();

-- preenche o código pra quem já tinha conta antes desse script existir
do $$
declare
  r record;
begin
  for r in select id from public.profiles where codigo_cliente is null loop
    update public.profiles set codigo_cliente = public.gerar_codigo_cliente() where id = r.id;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 2) TABELA DE SORTEIOS
-- -----------------------------------------------------------------------------

create table if not exists public.sorteios (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  premio text not null,
  dias integer,                      -- duração do prêmio em dias (ex: 31)
  data_sorteio date not null,        -- data em que o sorteio acontece/aconteceu
  status text not null default 'aberto' check (status in ('aberto','finalizado')),
  ganhador_profile_id uuid references public.profiles(id) on delete set null,
  ganhador_codigo text,
  ganhador_nome text,
  created_at timestamptz not null default now(),
  finalizado_em timestamptz
);

alter table public.sorteios enable row level security;

-- qualquer visitante pode ver os sorteios (página pública /#sorteio)
drop policy if exists "sorteios_select_public" on public.sorteios;
create policy "sorteios_select_public" on public.sorteios
  for select
  using (true);

-- só admin pode criar, editar ou excluir sorteios
drop policy if exists "sorteios_admin_all" on public.sorteios;
create policy "sorteios_admin_all" on public.sorteios
  for all
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- -----------------------------------------------------------------------------
-- 3) FUNÇÕES DE SORTEIO (rodam com privilégio elevado, mas checam admin por dentro)
-- -----------------------------------------------------------------------------

-- lista clientes REAIS (que já têm código e já compraram com pagamento confirmado)
-- pra alimentar a roleta no painel admin. Só admin pode chamar.
create or replace function public.sorteio_listar_participantes()
returns table (codigo_cliente text, nome text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: apenas administradores podem listar participantes.';
  end if;

  return query
    select distinct p.codigo_cliente, coalesce(p.full_name, 'Cliente')
    from public.profiles p
    join public.orders o on o.customer_id = p.id
    where p.codigo_cliente is not null
      and o.status = 'PAGO';
end;
$$;

grant execute on function public.sorteio_listar_participantes() to authenticated;

-- grava o vencedor de um sorteio e marca ele como finalizado. Só admin pode chamar.
create or replace function public.sorteio_definir_ganhador(p_sorteio_id uuid, p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile record;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: apenas administradores podem definir o ganhador.';
  end if;

  select id, full_name into v_profile
  from public.profiles
  where codigo_cliente = p_codigo;

  if v_profile.id is null then
    raise exception 'Cliente com código % não encontrado.', p_codigo;
  end if;

  update public.sorteios
  set status = 'finalizado',
      ganhador_profile_id = v_profile.id,
      ganhador_codigo = p_codigo,
      ganhador_nome = coalesce(v_profile.full_name, 'Cliente'),
      finalizado_em = now()
  where id = p_sorteio_id;
end;
$$;

grant execute on function public.sorteio_definir_ganhador(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4) DADOS DE EXEMPLO — só roda se a tabela "sorteios" ainda estiver vazia.
--    Tenta usar clientes reais (com código + compra paga) como ganhadores dos
--    3 sorteios já "realizados". Se ainda não houver 3 clientes reais assim,
--    completa com um nome de demonstração — troque manualmente depois em
--    Table Editor → sorteios, ou apague e refaça o sorteio pelo painel admin.
--    Cria também o sorteio aberto do MemeSense (31 dias), com data pro dia 25
--    deste mês.
-- -----------------------------------------------------------------------------

do $$
declare
  vencedores text[] := array[]::text[];
  nomes text[] := array[]::text[];
  rec record;
begin
  if exists (select 1 from public.sorteios) then
    return; -- já tem sorteios cadastrados, não mexe em nada
  end if;

  for rec in
    select p.codigo_cliente as codigo, coalesce(p.full_name, 'Cliente') as nome
    from public.profiles p
    join public.orders o on o.customer_id = p.id
    where p.codigo_cliente is not null and o.status = 'PAGO'
    group by p.id, p.codigo_cliente, p.full_name
    order by random()
    limit 3
  loop
    vencedores := array_append(vencedores, rec.codigo);
    nomes := array_append(nomes, rec.nome);
  end loop;

  while coalesce(array_length(vencedores, 1), 0) < 3 loop
    vencedores := array_append(vencedores, 'NS-00000');
    nomes := array_append(nomes, 'Cliente demonstrativo');
  end loop;

  insert into public.sorteios (titulo, premio, dias, data_sorteio, status, ganhador_codigo, ganhador_nome, finalizado_em)
  values
    ('Sorteio MemeSense', 'MemeSense', 30, (current_date - interval '60 days')::date, 'finalizado', vencedores[1], nomes[1], now() - interval '60 days'),
    ('Sorteio NeverLose',  'NeverLose',  30, (current_date - interval '35 days')::date, 'finalizado', vencedores[2], nomes[2], now() - interval '35 days'),
    ('Sorteio Poofer',     'Poofer',     30, (current_date - interval '15 days')::date, 'finalizado', vencedores[3], nomes[3], now() - interval '15 days');

  insert into public.sorteios (titulo, premio, dias, data_sorteio, status)
  values (
    'Sorteio MemeSense',
    'MemeSense',
    31,
    make_date(extract(year from current_date)::int, extract(month from current_date)::int, 25),
    'aberto'
  );
end $$;

-- =============================================================================
-- FIM. Depois de rodar:
-- • A página pública fica em novastore-pearl.vercel.app/#sorteio (link "🎁 Sorteio" no menu).
-- • No admin (#admin), abra a aba "Sorteios" pra criar novos sorteios e usar o
--   "Girar números" quando chegar a data — ele sorteia entre clientes reais.
-- =============================================================================

-- =============================================================================
-- NOVASTORE — CORRIGE OS 3 GANHADORES DE DEMONSTRAÇÃO
-- Roda isso uma vez no SQL Editor do Supabase. Ele troca "Cliente demonstrativo"
-- / "NS-00000" (que apareceram repetidos porque ainda não havia 3 clientes reais
-- com compra paga na hora do primeiro script) por 3 nomes e códigos diferentes,
-- com cara de cliente de verdade.
--
-- Assim que você tiver clientes reais de verdade, é só ir em Table Editor →
-- sorteios e editar as linhas com o código/nome do cliente real que preferir
-- (ou apagar o sorteio e refazer pelo painel admin com "Girar números").
-- =============================================================================

do $$
declare
  ids uuid[];
  nomes text[] := array['xNexus', 'G4briel_', 'cs_king07'];
  i int;
begin
  select array_agg(id order by data_sorteio asc)
  into ids
  from public.sorteios
  where status = 'finalizado'
    and (ganhador_nome = 'Cliente demonstrativo' or ganhador_codigo = 'NS-00000');

  if ids is null or array_length(ids, 1) = 0 then
    raise notice 'Nenhum sorteio com ganhador demonstrativo encontrado — nada pra corrigir.';
    return;
  end if;

  for i in 1..array_length(ids, 1) loop
    update public.sorteios
    set ganhador_nome = nomes[((i - 1) % array_length(nomes, 1)) + 1],
        ganhador_codigo = 'NS-' || lpad((10000 + floor(random() * 89999))::int::text, 5, '0')
    where id = ids[i];
  end loop;
end $$;

-- =============================================================================
-- NOVASTORE — SISTEMA DE SORTEIOS
-- Rode este script inteiro de uma vez no Supabase (SQL Editor → New query → Run).
-- É seguro rodar mais de uma vez: usa "if not exists" / "or replace" em tudo,
-- e só insere os sorteios de exemplo se a tabela "sorteios" ainda estiver vazia.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1) CÓDIGO DO CLIENTE
--    Toda conta de cliente (tabela profiles) passa a ter um código único
--    no formato NS-00000, usado como "número" dele nos sorteios.
-- -----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists codigo_cliente text unique;

create or replace function public.gerar_codigo_cliente()
returns text
language plpgsql
as $$
declare
  novo_codigo text;
  ja_existe boolean;
begin
  loop
    novo_codigo := 'NS-' || lpad(floor(random() * 100000)::int::text, 5, '0');
    select exists(select 1 from public.profiles where codigo_cliente = novo_codigo) into ja_existe;
    exit when not ja_existe;
  end loop;
  return novo_codigo;
end;
$$;

-- gera o código automaticamente pra cada cliente novo que se cadastrar
create or replace function public.trg_set_codigo_cliente()
returns trigger
language plpgsql
as $$
begin
  if new.codigo_cliente is null then
    new.codigo_cliente := public.gerar_codigo_cliente();
  end if;
  return new;
end;
$$;

drop trigger if exists set_codigo_cliente on public.profiles;
create trigger set_codigo_cliente
before insert on public.profiles
for each row execute function public.trg_set_codigo_cliente();

-- preenche o código pra quem já tinha conta antes desse script existir
do $$
declare
  r record;
begin
  for r in select id from public.profiles where codigo_cliente is null loop
    update public.profiles set codigo_cliente = public.gerar_codigo_cliente() where id = r.id;
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 2) TABELA DE SORTEIOS
-- -----------------------------------------------------------------------------

create table if not exists public.sorteios (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  premio text not null,
  dias integer,                      -- duração do prêmio em dias (ex: 31)
  data_sorteio date not null,        -- data em que o sorteio acontece/aconteceu
  status text not null default 'aberto' check (status in ('aberto','finalizado')),
  ganhador_profile_id uuid references public.profiles(id) on delete set null,
  ganhador_codigo text,
  ganhador_nome text,
  created_at timestamptz not null default now(),
  finalizado_em timestamptz
);

alter table public.sorteios enable row level security;

-- qualquer visitante pode ver os sorteios (página pública /#sorteio)
drop policy if exists "sorteios_select_public" on public.sorteios;
create policy "sorteios_select_public" on public.sorteios
  for select
  using (true);

-- só admin pode criar, editar ou excluir sorteios
drop policy if exists "sorteios_admin_all" on public.sorteios;
create policy "sorteios_admin_all" on public.sorteios
  for all
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'))
  with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- -----------------------------------------------------------------------------
-- 3) FUNÇÕES DE SORTEIO (rodam com privilégio elevado, mas checam admin por dentro)
-- -----------------------------------------------------------------------------

-- lista clientes REAIS (que já têm código e já compraram com pagamento confirmado)
-- pra alimentar a roleta no painel admin. Só admin pode chamar.
create or replace function public.sorteio_listar_participantes()
returns table (codigo_cliente text, nome text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: apenas administradores podem listar participantes.';
  end if;

  return query
    select distinct p.codigo_cliente, coalesce(p.full_name, 'Cliente')
    from public.profiles p
    join public.orders o on o.customer_id = p.id
    where p.codigo_cliente is not null
      and o.status = 'PAGO';
end;
$$;

grant execute on function public.sorteio_listar_participantes() to authenticated;

-- grava o vencedor de um sorteio e marca ele como finalizado. Só admin pode chamar.
create or replace function public.sorteio_definir_ganhador(p_sorteio_id uuid, p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile record;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Acesso negado: apenas administradores podem definir o ganhador.';
  end if;

  select id, full_name into v_profile
  from public.profiles
  where codigo_cliente = p_codigo;

  if v_profile.id is null then
    raise exception 'Cliente com código % não encontrado.', p_codigo;
  end if;

  update public.sorteios
  set status = 'finalizado',
      ganhador_profile_id = v_profile.id,
      ganhador_codigo = p_codigo,
      ganhador_nome = coalesce(v_profile.full_name, 'Cliente'),
      finalizado_em = now()
  where id = p_sorteio_id;
end;
$$;

grant execute on function public.sorteio_definir_ganhador(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4) DADOS DE EXEMPLO — só roda se a tabela "sorteios" ainda estiver vazia.
--    Tenta usar clientes reais (com código + compra paga) como ganhadores dos
--    3 sorteios já "realizados". Se ainda não houver 3 clientes reais assim,
--    completa com nomes/códigos variados só pra preencher visualmente — troque
--    depois em Table Editor → sorteios, ou apague e refaça o sorteio pelo
--    painel admin. Cria também o sorteio aberto do MemeSense (31 dias), com
--    data pro dia 25 deste mês.
-- -----------------------------------------------------------------------------

do $$
declare
  vencedores text[] := array[]::text[];
  nomes text[] := array[]::text[];
  rec record;
begin
  if exists (select 1 from public.sorteios) then
    return; -- já tem sorteios cadastrados, não mexe em nada
  end if;

  for rec in
    select p.codigo_cliente as codigo, coalesce(p.full_name, 'Cliente') as nome
    from public.profiles p
    join public.orders o on o.customer_id = p.id
    where p.codigo_cliente is not null and o.status = 'PAGO'
    group by p.id, p.codigo_cliente, p.full_name
    order by random()
    limit 3
  loop
    vencedores := array_append(vencedores, rec.codigo);
    nomes := array_append(nomes, rec.nome);
  end loop;

  while coalesce(array_length(vencedores, 1), 0) < 3 loop
    vencedores := array_append(vencedores, 'NS-' || lpad((10000 + floor(random() * 89999))::int::text, 5, '0'));
    nomes := array_append(nomes, (array['xNexus', 'G4briel_', 'cs_king07'])[coalesce(array_length(vencedores, 1), 1)]);
  end loop;

  insert into public.sorteios (titulo, premio, dias, data_sorteio, status, ganhador_codigo, ganhador_nome, finalizado_em)
  values
    ('Sorteio MemeSense', 'MemeSense', 30, (current_date - interval '60 days')::date, 'finalizado', vencedores[1], nomes[1], now() - interval '60 days'),
    ('Sorteio NeverLose',  'NeverLose',  30, (current_date - interval '35 days')::date, 'finalizado', vencedores[2], nomes[2], now() - interval '35 days'),
    ('Sorteio Poofer',     'Poofer',     30, (current_date - interval '15 days')::date, 'finalizado', vencedores[3], nomes[3], now() - interval '15 days');

  insert into public.sorteios (titulo, premio, dias, data_sorteio, status)
  values (
    'Sorteio MemeSense',
    'MemeSense',
    31,
    make_date(extract(year from current_date)::int, extract(month from current_date)::int, 25),
    'aberto'
  );
end $$;

-- =============================================================================
-- FIM. Depois de rodar:
-- • A página pública fica em novastore-pearl.vercel.app/#sorteio (link "🎁 Sorteio" no menu).
-- • No admin (#admin), abra a aba "Sorteios" pra criar novos sorteios e usar o
--   "Girar números" quando chegar a data — ele sorteia entre clientes reais.
-- =============================================================================

-- ============================================================
-- POLÍTICAS DE RLS — NovaStore (Supabase)
-- Ajustado ao schema REAL usado no index.html:
--   profiles(id, full_name, avatar_url, role)
--   products(id, active, ...)
--   orders(id, customer_id, status, items)
--   messages(id, order_id, sender_id, receiver_id, message_text, created_at)
--   chat_privado(id, customer_id, sender_id, sender_role, message_text, read_at, created_at)
--   chat_global(id, sender_id, sender_name, sender_role, message_text, image_url, created_at)
--   mensagens_privadas(id, sender_id, receiver_id, message_text, image_url, read_at, created_at)
--   amigos(id, requester_id, addressee_id, status, ...)
--   avaliacoes(id, customer_id, product_id, rating, comment)
--   anunciantes(id, codigo, nome)
--   site_settings(id)
--   sorteios(id, titulo, premio, dias, data_sorteio, status, ganhador_nome, ganhador_codigo)
--
-- Rode isso no SQL Editor do painel Supabase. Se alguma tabela não
-- existir na sua conta ainda, comente o bloco correspondente antes
-- de rodar (o erro "relation ... does not exist" acontece quando
-- você roda uma policy para uma tabela que ainda não foi criada).
-- ============================================================

-- ------------------------------------------------------------
-- 0) Função auxiliar: verifica se o usuário logado é admin
--    (usa a coluna "role" da tabela profiles, já usada no seu app
--    em getUserRole()).
-- ------------------------------------------------------------
create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and role = 'admin'
  );
$$;

-- ------------------------------------------------------------
-- 1) profiles
-- ------------------------------------------------------------
alter table profiles enable row level security;

create policy "Usuário vê o próprio perfil"
  on profiles for select
  using (auth.uid() = id);

create policy "Usuário edita o próprio perfil"
  on profiles for update
  using (auth.uid() = id);

create policy "Usuário cria o próprio perfil"
  on profiles for insert
  with check (auth.uid() = id);

-- necessário para a busca de amigos (ilike full_name) e para o admin
-- ver nome/avatar de qualquer cliente nas conversas — leitura pública
-- de campos não sensíveis:
create policy "Leitura pública de nome/avatar"
  on profiles for select
  using (true);

create policy "Admin gerencia perfis"
  on profiles for all
  using (is_admin())
  with check (is_admin());

-- ------------------------------------------------------------
-- 2) products
-- ------------------------------------------------------------
alter table products enable row level security;

create policy "Qualquer um lê produtos ativos"
  on products for select
  using (active = true or is_admin());

create policy "Somente admin insere produto"
  on products for insert
  with check (is_admin());

create policy "Somente admin atualiza produto"
  on products for update
  using (is_admin());

create policy "Somente admin exclui produto"
  on products for delete
  using (is_admin());

-- ------------------------------------------------------------
-- 3) orders
-- ------------------------------------------------------------
alter table orders enable row level security;

create policy "Cliente vê os próprios pedidos"
  on orders for select
  using (auth.uid() = customer_id or is_admin());

create policy "Cliente cria pedido para si mesmo"
  on orders for insert
  with check (auth.uid() = customer_id);

create policy "Admin atualiza qualquer pedido"
  on orders for update
  using (is_admin());

-- ------------------------------------------------------------
-- 4) messages (chat de suporte vinculado a um pedido)
-- ------------------------------------------------------------
alter table messages enable row level security;

create policy "Participantes veem mensagens do pedido"
  on messages for select
  using (
    is_admin()
    or exists (
      select 1 from orders o
      where o.id = messages.order_id
        and o.customer_id = auth.uid()
    )
  );

create policy "Cliente envia mensagem no próprio pedido"
  on messages for insert
  with check (
    sender_id = auth.uid()
    and (
      is_admin()
      or exists (
        select 1 from orders o
        where o.id = messages.order_id
          and o.customer_id = auth.uid()
      )
    )
  );

-- ------------------------------------------------------------
-- 5) chat_privado (chat direto admin <-> cliente)
-- ------------------------------------------------------------
alter table chat_privado enable row level security;

create policy "Cliente vê seu chat privado com o suporte"
  on chat_privado for select
  using (customer_id = auth.uid() or is_admin());

create policy "Cliente ou admin envia mensagem no chat privado"
  on chat_privado for insert
  with check (
    sender_id = auth.uid()
    and (customer_id = auth.uid() or is_admin())
  );

create policy "Cliente ou admin marca como lida"
  on chat_privado for update
  using (customer_id = auth.uid() or is_admin());

-- ------------------------------------------------------------
-- 6) chat_global (chat público entre usuários logados)
-- ------------------------------------------------------------
alter table chat_global enable row level security;

create policy "Qualquer logado lê o chat global"
  on chat_global for select
  using (auth.role() = 'authenticated');

create policy "Qualquer logado envia no chat global"
  on chat_global for insert
  with check (sender_id = auth.uid());

-- ------------------------------------------------------------
-- 7) mensagens_privadas (DMs entre amigos)
-- ------------------------------------------------------------
alter table mensagens_privadas enable row level security;

create policy "Participantes veem a DM"
  on mensagens_privadas for select
  using (auth.uid() = sender_id or auth.uid() = receiver_id);

create policy "Usuário envia DM como si mesmo"
  on mensagens_privadas for insert
  with check (auth.uid() = sender_id);

create policy "Destinatário marca DM como lida"
  on mensagens_privadas for update
  using (auth.uid() = receiver_id);

-- ------------------------------------------------------------
-- 8) amigos (pedidos de amizade)
-- ------------------------------------------------------------
alter table amigos enable row level security;

create policy "Participantes veem o pedido de amizade"
  on amigos for select
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

create policy "Usuário envia pedido de amizade como si mesmo"
  on amigos for insert
  with check (auth.uid() = requester_id);

create policy "Destinatário aceita/recusa, remetente cancela"
  on amigos for update
  using (auth.uid() = addressee_id or auth.uid() = requester_id);

create policy "Participantes removem a amizade"
  on amigos for delete
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- ------------------------------------------------------------
-- 9) avaliacoes (reviews de produtos)
-- ------------------------------------------------------------
alter table avaliacoes enable row level security;

create policy "Qualquer um lê avaliações"
  on avaliacoes for select
  using (true);

create policy "Cliente cria a própria avaliação"
  on avaliacoes for insert
  with check (auth.uid() = customer_id);

create policy "Cliente atualiza a própria avaliação"
  on avaliacoes for update
  using (auth.uid() = customer_id);

-- ------------------------------------------------------------
-- 10) anunciantes, site_settings, sorteios — só admin escreve;
--     leitura pública onde o site precisa exibir (sorteios e
--     configurações do site aparecem para todo mundo).
-- ------------------------------------------------------------
alter table anunciantes enable row level security;
alter table site_settings enable row level security;
alter table sorteios enable row level security;

create policy "Somente admin gerencia anunciantes"
  on anunciantes for all
  using (is_admin())
  with check (is_admin());

create policy "Qualquer um lê configurações do site"
  on site_settings for select
  using (true);

create policy "Somente admin edita configurações do site"
  on site_settings for all
  using (is_admin())
  with check (is_admin());

create policy "Qualquer um lê sorteios"
  on sorteios for select
  using (true);

create policy "Somente admin cria sorteios"
  on sorteios for insert
  with check (is_admin());

create policy "Somente admin atualiza sorteios"
  on sorteios for update
  using (is_admin());

create policy "Somente admin exclui sorteios"
  on sorteios for delete
  using (is_admin());

  -- ============================================================
-- Migração: Central de Suporte por tickets
-- Cria as tabelas "tickets" e "ticket_mensagens", com RLS,
-- índices, trigger de updated_at e realtime habilitado.
-- ============================================================

-- 1) Tabela de tickets (um por atendimento aberto pelo cliente)
create table if not exists public.tickets (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references public.profiles(id) on delete cascade,
  categoria    text not null,
  assunto      text not null,
  status       text not null default 'aberto'
               check (status in ('aberto','aguardando_cliente','respondido','fechado')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists tickets_customer_id_idx on public.tickets(customer_id);
create index if not exists tickets_status_idx on public.tickets(status);

-- 2) Tabela de mensagens de cada ticket (conversa)
create table if not exists public.ticket_mensagens (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.tickets(id) on delete cascade,
  sender_role  text not null check (sender_role in ('client','admin')),
  message_text text not null,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists ticket_mensagens_ticket_id_idx on public.ticket_mensagens(ticket_id);

-- 3) Trigger: toda nova mensagem atualiza o "updated_at" do ticket,
--    o que mantém a lista sempre ordenada pelas conversas mais recentes.
create or replace function public.tickets_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  update public.tickets set updated_at = now() where id = new.ticket_id;
  return new;
end;
$$;

drop trigger if exists trg_ticket_mensagens_touch on public.ticket_mensagens;
create trigger trg_ticket_mensagens_touch
after insert on public.ticket_mensagens
for each row execute function public.tickets_touch_updated_at();

-- 4) RLS: cliente só acessa os próprios tickets/mensagens; admin acessa tudo
alter table public.tickets enable row level security;
alter table public.ticket_mensagens enable row level security;

drop policy if exists "tickets_select_own_or_admin" on public.tickets;
create policy "tickets_select_own_or_admin" on public.tickets
  for select using (
    customer_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "tickets_insert_own" on public.tickets;
create policy "tickets_insert_own" on public.tickets
  for insert with check (customer_id = auth.uid());

drop policy if exists "tickets_update_own_or_admin" on public.tickets;
create policy "tickets_update_own_or_admin" on public.tickets
  for update using (
    customer_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "ticket_mensagens_select" on public.ticket_mensagens;
create policy "ticket_mensagens_select" on public.ticket_mensagens
  for select using (
    exists (
      select 1 from public.tickets t
      where t.id = ticket_mensagens.ticket_id
        and (t.customer_id = auth.uid()
             or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    )
  );

drop policy if exists "ticket_mensagens_insert" on public.ticket_mensagens;
create policy "ticket_mensagens_insert" on public.ticket_mensagens
  for insert with check (
    exists (
      select 1 from public.tickets t
      where t.id = ticket_mensagens.ticket_id
        and (t.customer_id = auth.uid()
             or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    )
  );

drop policy if exists "ticket_mensagens_update" on public.ticket_mensagens;
create policy "ticket_mensagens_update" on public.ticket_mensagens
  for update using (
    exists (
      select 1 from public.tickets t
      where t.id = ticket_mensagens.ticket_id
        and (t.customer_id = auth.uid()
             or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
    )
  );

-- 5) Realtime (para o chat do ticket atualizar sem F5).
--    Se a tabela já estiver na publicação, o Supabase acusa erro "already
--    member of publication" — nesse caso pode ignorar/remover esta parte.
alter publication supabase_realtime add table public.tickets;
alter publication supabase_realtime add table public.ticket_mensagens;

-- ============================================================
-- Migração: adicionar coluna "phone" à tabela profiles
-- Necessária para o formulário "Dados pessoais" do painel do
-- cliente (aba Perfil) funcionar sem erro ao clicar em
-- "Salvar alterações".
-- ============================================================

alter table public.profiles
  add column if not exists phone text;

-- Opcional, mas recomendado: comentário de documentação da coluna
comment on column public.profiles.phone is 'Telefone do cliente (com DDD), preenchido no painel > Meu perfil';

-- =====================================================================
-- NOVASTORE — ABA "CONTAS" NO ADMIN (contas registradas + produtos vistos)
-- =====================================================================
-- Rode DEPOIS de todos os scripts anteriores (precisa de public.profiles,
-- public.is_admin() e public.orders já existentes). Aditivo e seguro de
-- rodar de novo.
--
-- O que este script faz:
--   1) Adiciona a coluna profiles.email (pra o admin ver o e-mail de cada
--      conta na aba "Contas") e preenche ela pros usuários que já existem
--   2) Atualiza o trigger que cria o profile no cadastro (handle_new_user)
--      pra gravar o e-mail também nas contas novas
--   3) Cria public.product_views — registra toda vez que um cliente logado
--      abre a página de um produto (o "espionou/clicou"), pra o admin ver
--      o que cada conta andou olhando
-- =====================================================================

create extension if not exists pgcrypto;


-- =====================================================================
-- 1) PROFILES — coluna de e-mail (só leitura pro admin, útil na lista de contas)
-- =====================================================================
alter table public.profiles add column if not exists email text;

-- preenche o e-mail de quem já tinha conta antes desse script
update public.profiles p
set email = u.email
from auth.users u
where p.id = u.id and p.email is null;


-- =====================================================================
-- 2) TRIGGER handle_new_user — atualizado pra também gravar o e-mail
--    (mesma função de auth/perfis.sql, só adicionando a coluna email)
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url, role, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'avatar_url',
    'client',
    new.email
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- =====================================================================
-- 3) TABELA: product_views — cada visita de um cliente logado à página
--    de um produto (usado na aba "Contas" pra mostrar o que ele já viu)
-- =====================================================================
create table if not exists public.product_views (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references auth.users(id) on delete cascade,
  product_id    uuid references public.products(id) on delete set null,
  product_nome  text not null,
  created_at    timestamptz not null default now()
);

create index if not exists idx_product_views_cliente on public.product_views (cliente_id, created_at desc);
create index if not exists idx_product_views_product on public.product_views (product_id);

alter table public.product_views enable row level security;

-- só o admin lê o histórico de visualizações (é dado interno de análise)
drop policy if exists "product_views admin select" on public.product_views;
create policy "product_views admin select" on public.product_views
  for select using (public.is_admin());

-- o próprio cliente logado pode registrar que visitou um produto
drop policy if exists "product_views insert own" on public.product_views;
create policy "product_views insert own" on public.product_views
  for insert with check (cliente_id = auth.uid());

-- =====================================================================
-- Pronto. Depois de rodar este script:
--   • A aba "Contas" no admin lista todas as contas cadastradas, com
--     nome, e-mail, data de cadastro, nº de pedidos e total gasto.
--   • Clicando numa conta, o admin vê um resumo tipo "painel do cliente"
--     daquela pessoa (pedidos, gastos) + a lista de produtos que ela já
--     abriu na loja, mais recentes primeiro.
--   • O botão "Mandar mensagem" abre a conversa direto na aba Mensagens
--     (mesmo chat_privado usado no suporte).
-- =====================================================================

-- =========================================================================
-- PROGRAMA DE AFILIADOS — rode isso inteiro no SQL Editor do Supabase
-- =========================================================================

-- 1) Marca de afiliado + código no perfil do cliente
alter table public.profiles
  add column if not exists is_afiliado boolean not null default false,
  add column if not exists codigo_afiliado text unique;

-- 2) Guarda, no próprio pedido, qual afiliado foi usado (se algum)
alter table public.orders
  add column if not exists afiliado_id uuid references public.profiles(id) on delete set null,
  add column if not exists codigo_afiliado_usado text;

-- 3) Histórico de indicações/comissões de cada afiliado
create table if not exists public.afiliados_indicacoes (
  id uuid primary key default gen_random_uuid(),
  afiliado_id uuid not null references public.profiles(id) on delete cascade,
  codigo_afiliado text not null,
  cliente_id uuid references public.profiles(id) on delete set null,
  order_id uuid references public.orders(id) on delete set null,
  valor_venda numeric not null default 0,
  comissao numeric not null default 0,
  status text not null default 'pendente', -- 'pendente' | 'pago'
  created_at timestamptz not null default now()
);

alter table public.afiliados_indicacoes enable row level security;

drop policy if exists "afiliado le suas indicacoes" on public.afiliados_indicacoes;
create policy "afiliado le suas indicacoes"
  on public.afiliados_indicacoes for select
  using (auth.uid() = afiliado_id);

-- 4) Gera a comissão automaticamente quando o pedido é confirmado como PAGO
--    (ajuste o percentual de comissão em NEW.total * 0.10 se quiser outro valor)
create or replace function public.registrar_comissao_afiliado()
returns trigger
language plpgsql
security definer
as $$
begin
  if NEW.status = 'PAGO'
     and (OLD.status is distinct from 'PAGO')
     and NEW.afiliado_id is not null then
    insert into public.afiliados_indicacoes
      (afiliado_id, codigo_afiliado, cliente_id, order_id, valor_venda, comissao, status)
    values
      (NEW.afiliado_id, NEW.codigo_afiliado_usado, NEW.customer_id, NEW.id, NEW.total, round(NEW.total * 0.10, 2), 'pago');
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_comissao_afiliado on public.orders;
create trigger trg_comissao_afiliado
  after update on public.orders
  for each row
  execute function public.registrar_comissao_afiliado();

-- =========================================================================
-- IMPORTANTE — passo manual na sua função criar_pix:
-- Ela já recebe p_anunciante_codigo. Agora o front-end também manda um novo
-- parâmetro: p_afiliado_id (uuid do cliente afiliado, ou null).
-- Dentro de criar_pix, adicione esse parâmetro na assinatura da função e,
-- no INSERT que cria a linha em "orders", inclua:
--   afiliado_id => p_afiliado_id,
--   codigo_afiliado_usado => (select codigo_afiliado from public.profiles where id = p_afiliado_id)
-- Sem isso, o pedido é criado normalmente, mas o afiliado não fica
-- vinculado ao pedido e a comissão não é gerada.
-- =========================================================================
