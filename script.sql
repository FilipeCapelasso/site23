SQL 1:

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

SQL 2:
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
