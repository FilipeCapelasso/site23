-- =====================================================================================
-- NOVASTORE — SCRIPT SQL SUPREMO (v3, consolidado)
-- =====================================================================================
-- Este arquivo substitui TODOS os scripts anteriores. Ele contém, em ordem correta
-- de dependência, tudo que o site precisa para funcionar 100%:
--
--   1.  Extensões (pgcrypto, http, pg_cron)
--   2.  profiles + is_admin() + criação automática de perfil + código de cliente
--   3.  products
--   4.  site_settings (aparência, tema, efeitos)
--   5.  orders
--   6.  anunciantes + histórico de vendas
--   7.  Programa de afiliados (código #0000, indicações, comissões)
--   8.  criar_pix() — VERSÃO ÚNICA E DEFINITIVA (Pix + código + desconto de 10%)
--   9.  Confirmação automática de pagamento (Mercado Pago + pg_cron)
--   10. messages (chat por pedido)
--   11. chat_global / chat_privado
--   12. amigos / mensagens_privadas
--   13. avaliacoes
--   14. sorteios
--   15. tickets (central de suporte)
--   16. product_views
--   17. Storage (buckets de imagem)
--   18. Passos manuais finais (token do Mercado Pago + virar admin)
--
-- É SEGURO rodar este arquivo inteiro de uma vez, quantas vezes quiser, em um projeto
-- que já tem dados: tudo usa IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS
-- e NENHUM comando apaga dados existentes.
--
-- REGRAS DE NEGÓCIO DESTA VERSÃO:
--   • Todo código de indicação (anunciante OU afiliado) tem o formato #0000
--     (o caractere "#" seguido de exatamente 4 dígitos).
--   • Um código de anunciante e um de afiliado nunca podem ser iguais, porque os
--     dois são digitados no mesmo campo do checkout.
--   • Usar um código dá 10% DE DESCONTO em compras a partir de R$ 80,00.
--   • Quando o pedido é confirmado como PAGO, o afiliado ganha 10% de comissão.
-- =====================================================================================


-- =====================================================================================
-- 1) EXTENSÕES
-- =====================================================================================
create extension if not exists pgcrypto;
create extension if not exists http with schema extensions;

do $$
begin
  create extension if not exists pg_cron with schema extensions;
exception when others then
  raise notice 'pg_cron não pôde ser criado automaticamente (%). Se a confirmação automática de pagamento não funcionar, ative a extensão "pg_cron" em Database → Extensions no painel do Supabase.', sqlerrm;
end $$;


-- =====================================================================================
-- 2) PROFILES — perfil de cada usuário, base de todo o controle de permissão
-- =====================================================================================
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  email       text,
  phone       text,
  role        text not null default 'client' check (role in ('admin','client')),
  created_at  timestamptz default now()
);

-- colunas que foram sendo adicionadas ao longo do tempo
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists codigo_cliente text;
alter table public.profiles add column if not exists tem_cupom_proxima_compra boolean not null default false;
alter table public.profiles add column if not exists is_afiliado boolean not null default false;
alter table public.profiles add column if not exists codigo_afiliado text;

-- índices únicos (como índice, e não constraint, pra poder usar IF NOT EXISTS)
create unique index if not exists profiles_codigo_cliente_key
  on public.profiles (codigo_cliente) where codigo_cliente is not null;
create unique index if not exists profiles_codigo_afiliado_key
  on public.profiles (codigo_afiliado) where codigo_afiliado is not null;

alter table public.profiles enable row level security;

-- -------------------------------------------------------------------------------------
-- is_admin(): usada em quase todas as policies. É SECURITY DEFINER pra não cair em
-- recursão de RLS ao consultar a própria tabela profiles dentro de uma policy dela.
-- -------------------------------------------------------------------------------------
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

-- Leitura: o dono lê o próprio perfil; o admin lê todos.
-- Além disso, qualquer usuário logado precisa conseguir ler nome/avatar dos outros
-- (busca de amigos, chat global, painel). Como o Postgres não filtra por COLUNA em RLS,
-- liberamos o SELECT para autenticados — não há dado sensível em profiles além do
-- e-mail/telefone, que o site nunca exibe para terceiros.
drop policy if exists "users read own profile" on public.profiles;
drop policy if exists "profiles select" on public.profiles;
create policy "profiles select" on public.profiles
  for select using (auth.role() = 'authenticated' or public.is_admin());

drop policy if exists "users update own profile" on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles
  for update using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

-- Não existe policy de INSERT: o perfil nasce pela trigger abaixo (SECURITY DEFINER).

-- -------------------------------------------------------------------------------------
-- Código de cliente (NS-00000) — usado como "número da sorte" nos sorteios
-- -------------------------------------------------------------------------------------
create or replace function public.gerar_codigo_cliente()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  novo_codigo text;
  ja_existe   boolean;
begin
  loop
    novo_codigo := 'NS-' || lpad(floor(random() * 100000)::int::text, 5, '0');
    select exists(select 1 from public.profiles where codigo_cliente = novo_codigo) into ja_existe;
    exit when not ja_existe;
  end loop;
  return novo_codigo;
end;
$$;

create or replace function public.trg_set_codigo_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
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

-- preenche o código de quem já tinha conta antes desta regra existir
do $$
declare r record;
begin
  for r in select id from public.profiles where codigo_cliente is null loop
    update public.profiles set codigo_cliente = public.gerar_codigo_cliente() where id = r.id;
  end loop;
end $$;

-- -------------------------------------------------------------------------------------
-- Cria o profile automaticamente quando alguém se cadastra (supabase.auth.signUp)
-- -------------------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'avatar_url',
    new.email,
    'client'
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- preenche o e-mail de quem já tinha conta antes da coluna existir
update public.profiles p
set email = u.email
from auth.users u
where u.id = p.id and p.email is null;


-- =====================================================================================
-- 3) PRODUCTS
-- =====================================================================================
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  slug         text,
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
create index if not exists idx_products_active   on public.products (active);

alter table public.products enable row level security;

drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products
  for select using (active = true or public.is_admin());

drop policy if exists "admin full access products" on public.products;
create policy "admin full access products" on public.products
  for all using (public.is_admin()) with check (public.is_admin());


-- =====================================================================================
-- 4) SITE_SETTINGS — banner, fundo, tema de cores e efeitos
-- =====================================================================================
create table if not exists public.site_settings (
  id                   int primary key default 1,
  hero_image_url       text,
  hero_overlay         numeric not null default 0.35,
  background_image_url text,
  background_overlay   numeric not null default 0.85,
  updated_at           timestamptz not null default now()
);

alter table public.site_settings add column if not exists theme_primary    text not null default '#7c5cff';
alter table public.site_settings add column if not exists theme_accent     text not null default '#00e6a8';
alter table public.site_settings add column if not exists effect_lightning boolean not null default false;
alter table public.site_settings add column if not exists updated_at       timestamptz not null default now();

insert into public.site_settings (id) values (1) on conflict (id) do nothing;

alter table public.site_settings enable row level security;

-- a aparência precisa ser lida por visitantes não logados
drop policy if exists "public read settings"        on public.site_settings;
drop policy if exists "site_settings select public" on public.site_settings;
create policy "site_settings select public" on public.site_settings
  for select using (true);

drop policy if exists "admin write settings"      on public.site_settings;
drop policy if exists "site_settings upsert admin" on public.site_settings;
create policy "site_settings upsert admin" on public.site_settings
  for insert with check (public.is_admin());

drop policy if exists "site_settings update admin" on public.site_settings;
create policy "site_settings update admin" on public.site_settings
  for update using (public.is_admin()) with check (public.is_admin());


-- =====================================================================================
-- 5) ORDERS — pedidos + Pix
-- =====================================================================================
create table if not exists public.orders (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid references auth.users(id),
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

alter table public.orders add column if not exists customer_id uuid references auth.users(id);
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

-- indicação / desconto
alter table public.orders add column if not exists anunciante_codigo text;
alter table public.orders add column if not exists cupom_usado boolean not null default false;
alter table public.orders add column if not exists desconto_aplicado numeric not null default 0;
alter table public.orders add column if not exists afiliado_id uuid references public.profiles(id) on delete set null;
alter table public.orders add column if not exists codigo_afiliado_usado text;

create index if not exists idx_orders_customer_id on public.orders (customer_id);
create index if not exists idx_orders_status      on public.orders (status);
create index if not exists idx_orders_afiliado    on public.orders (afiliado_id);

alter table public.orders enable row level security;

drop policy if exists "admin can view orders"    on public.orders;
drop policy if exists "customers read own orders" on public.orders;
drop policy if exists "orders select"            on public.orders;
create policy "orders select" on public.orders
  for select using (public.is_admin() or auth.uid() = customer_id);

drop policy if exists "admin can update orders" on public.orders;
drop policy if exists "orders update"           on public.orders;
create policy "orders update" on public.orders
  for update using (public.is_admin());

-- Não há policy de INSERT: pedidos só nascem dentro de criar_pix() (SECURITY DEFINER).


-- =====================================================================================
-- 6) ANUNCIANTES — códigos de indicação no formato #0000
-- =====================================================================================
create table if not exists public.anunciantes (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  codigo       text not null unique,
  total_vendas integer not null default 0,
  created_at   timestamptz not null default now()
);

alter table public.anunciantes enable row level security;

-- qualquer cliente logado pode validar um código no checkout
drop policy if exists "anunciantes select authenticated" on public.anunciantes;
create policy "anunciantes select authenticated" on public.anunciantes
  for select using (auth.role() = 'authenticated');

drop policy if exists "anunciantes admin insert" on public.anunciantes;
create policy "anunciantes admin insert" on public.anunciantes
  for insert with check (public.is_admin());

drop policy if exists "anunciantes admin update" on public.anunciantes;
create policy "anunciantes admin update" on public.anunciantes
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "anunciantes admin delete" on public.anunciantes;
create policy "anunciantes admin delete" on public.anunciantes
  for delete using (public.is_admin());

-- -------------------------------------------------------------------------------------
-- Histórico de vendas feitas com cada código de anunciante
-- -------------------------------------------------------------------------------------
create table if not exists public.historico_vendas_anunciantes (
  id             uuid primary key default gen_random_uuid(),
  anunciante_id  uuid not null references public.anunciantes(id) on delete cascade,
  cliente_id     uuid references auth.users(id),
  cliente_nome   text,
  produto_nome   text not null,
  valor_compra   numeric not null,
  created_at     timestamptz not null default now()
);

create index if not exists idx_historico_anunciante
  on public.historico_vendas_anunciantes (anunciante_id, created_at desc);

alter table public.historico_vendas_anunciantes enable row level security;

drop policy if exists "historico admin select" on public.historico_vendas_anunciantes;
create policy "historico admin select" on public.historico_vendas_anunciantes
  for select using (public.is_admin());


-- =====================================================================================
-- 7) PROGRAMA DE AFILIADOS
-- =====================================================================================
create table if not exists public.afiliados_indicacoes (
  id              uuid primary key default gen_random_uuid(),
  afiliado_id     uuid not null references public.profiles(id) on delete cascade,
  codigo_afiliado text not null,
  cliente_id      uuid references public.profiles(id) on delete set null,
  order_id        uuid references public.orders(id) on delete set null,
  valor_venda     numeric not null default 0,
  comissao        numeric not null default 0,
  status          text not null default 'pendente' check (status in ('pendente','pago')),
  created_at      timestamptz not null default now()
);

create index if not exists idx_afiliados_indicacoes_afiliado
  on public.afiliados_indicacoes (afiliado_id, created_at desc);

alter table public.afiliados_indicacoes enable row level security;

drop policy if exists "afiliado le suas indicacoes" on public.afiliados_indicacoes;
create policy "afiliado le suas indicacoes" on public.afiliados_indicacoes
  for select using (auth.uid() = afiliado_id or public.is_admin());

-- -------------------------------------------------------------------------------------
-- Gerador de código #0000 que NUNCA colide com um anunciante nem com outro afiliado.
-- O site chama isso pelo front, mas deixar a função aqui garante que qualquer
-- código gerado direto no banco siga a mesma regra.
-- -------------------------------------------------------------------------------------
create or replace function public.gerar_codigo_indicacao()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo    text;
  v_tentativas int := 0;
begin
  loop
    v_codigo := '#' || lpad(floor(random() * 10000)::int::text, 4, '0');

    exit when not exists (select 1 from public.anunciantes where codigo = v_codigo)
          and not exists (select 1 from public.profiles   where codigo_afiliado = v_codigo);

    v_tentativas := v_tentativas + 1;
    if v_tentativas > 200 then
      raise exception 'Não foi possível gerar um código de indicação livre (todos os 10.000 códigos #0000 parecem estar em uso).';
    end if;
  end loop;

  return v_codigo;
end;
$$;

grant execute on function public.gerar_codigo_indicacao() to authenticated;

-- -------------------------------------------------------------------------------------
-- Afiliar uma conta: gera o código e marca o perfil. Só admin pode chamar.
-- (O site também faz isso direto por UPDATE; esta função é o caminho seguro.)
-- -------------------------------------------------------------------------------------
create or replace function public.afiliar_cliente(p_cliente_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas administradores podem afiliar contas.';
  end if;

  select codigo_afiliado into v_codigo
  from public.profiles where id = p_cliente_id and is_afiliado = true;

  if v_codigo is not null then
    return v_codigo; -- já é afiliado, devolve o código existente
  end if;

  v_codigo := public.gerar_codigo_indicacao();

  update public.profiles
  set is_afiliado = true, codigo_afiliado = v_codigo
  where id = p_cliente_id;

  return v_codigo;
end;
$$;

grant execute on function public.afiliar_cliente(uuid) to authenticated;


-- =====================================================================================
-- 8) MERCADO PAGO — token guardado no Vault
-- =====================================================================================
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


-- =====================================================================================
-- 9) get_order_status — o site consulta isso pra saber se o Pix caiu
-- =====================================================================================
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


-- =====================================================================================
-- 10) criar_pix() — VERSÃO ÚNICA E DEFINITIVA
-- =====================================================================================
-- IMPORTANTE: versões antigas desta função (com 3, 4 e 6 parâmetros) são REMOVIDAS
-- abaixo. Se duas sobrecargas coexistirem, o PostgREST não consegue decidir qual
-- chamar e o site passa a receber o erro "Could not choose the best candidate function".
-- =====================================================================================
drop function if exists public.criar_pix(text, text, jsonb);
drop function if exists public.criar_pix(text, text, jsonb, uuid);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text, boolean);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text, uuid, boolean);

create or replace function public.criar_pix(
  p_name              text,
  p_email             text,
  p_items             jsonb,
  p_customer_id       uuid default null,
  p_anunciante_codigo text default null,
  p_afiliado_id       uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token           text;
  v_subtotal        numeric;
  v_total           numeric;
  v_order_id        uuid;
  v_expires_at      timestamptz := now() + interval '30 minutes';
  v_first_name      text;
  v_last_name       text;
  v_payload         jsonb;
  v_response        http_response;
  v_mp              jsonb;
  v_qr_code         text;
  v_qr_base64       text;
  v_mp_id           text;
  v_codigo          text;
  v_codigo_afiliado text;
  v_desconto        numeric := 0;
  v_tem_indicacao   boolean := false;
  -- >>> regra de negócio: 10% de desconto em compras a partir de R$ 80,00 <<<
  c_desconto_pct    constant numeric := 0.10;
  c_valor_minimo    constant numeric := 80;
begin
  if p_name is null or p_email is null or p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'Dados incompletos para gerar o Pix.');
  end if;

  select coalesce(sum((item->>'price')::numeric * coalesce((item->>'quantity')::numeric, 1)), 0)
  into v_subtotal
  from jsonb_array_elements(p_items) as item;

  if v_subtotal <= 0 then
    return jsonb_build_object('error', 'Valor do pedido inválido.');
  end if;

  -- ---- valida o código de ANUNCIANTE, se informado -----------------------------------
  v_codigo := nullif(trim(p_anunciante_codigo), '');
  if v_codigo is not null then
    if not exists (select 1 from public.anunciantes where codigo = v_codigo) then
      return jsonb_build_object('error', 'Código de anunciante inválido.');
    end if;
    v_tem_indicacao := true;
  end if;

  -- ---- valida o código de AFILIADO, se informado --------------------------------------
  if p_afiliado_id is not null then
    select codigo_afiliado into v_codigo_afiliado
    from public.profiles
    where id = p_afiliado_id and is_afiliado = true;

    if v_codigo_afiliado is null then
      return jsonb_build_object('error', 'Código de afiliado inválido.');
    end if;

    -- ninguém pode usar o próprio código de afiliado pra se dar desconto
    if p_customer_id is not null and p_customer_id = p_afiliado_id then
      return jsonb_build_object('error', 'Você não pode usar o seu próprio código de afiliado.');
    end if;

    v_tem_indicacao := true;
  end if;

  -- ---- aplica os 10% se houver indicação e o subtotal atingir o mínimo ----------------
  if v_tem_indicacao and v_subtotal >= c_valor_minimo then
    v_desconto := round(v_subtotal * c_desconto_pct, 2);
  end if;

  v_total := greatest(v_subtotal - v_desconto, 0.01);

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return jsonb_build_object('error', 'Token do Mercado Pago não configurado. Cadastre o segredo "mp_access_token" no Vault do Supabase.');
  end if;

  insert into public.orders (
    customer_name, customer_email, customer_id, items, total, status, expires_at,
    anunciante_codigo, cupom_usado, desconto_aplicado,
    afiliado_id, codigo_afiliado_usado
  )
  values (
    p_name, p_email, p_customer_id, p_items, v_total, 'PENDENTE', v_expires_at,
    v_codigo, (v_desconto > 0), v_desconto,
    p_afiliado_id, v_codigo_afiliado
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
      coalesce((v_response.content::jsonb ->> 'message'),
               'Erro ao gerar cobrança Pix no Mercado Pago (status ' || v_response.status || ').')
    );
  end if;

  v_mp        := v_response.content::jsonb;
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
    'orderId',          v_order_id,
    'qrCode',           v_qr_code,
    'qrCodeBase64',     v_qr_base64,
    'expiresAt',        v_expires_at,
    'subtotal',         v_subtotal,
    'total',            v_total,
    'descontoAplicado', v_desconto
  );
end;
$$;

revoke all on function public.criar_pix(text, text, jsonb, uuid, text, uuid) from public;
grant execute on function public.criar_pix(text, text, jsonb, uuid, text, uuid) to anon, authenticated;


-- =====================================================================================
-- 11) TRIGGER — o que acontece quando um pedido vira PAGO
-- =====================================================================================
--   a) código de anunciante: +1 venda, registra no histórico
--   b) código de afiliado:   gera a comissão de 10% pro afiliado
-- =====================================================================================
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

    -- (a) anunciante ---------------------------------------------------------------
    if new.anunciante_codigo is not null then
      select * into v_anunciante from public.anunciantes where codigo = new.anunciante_codigo;

      if found then
        update public.anunciantes
        set total_vendas = total_vendas + 1
        where id = v_anunciante.id;

        for v_item in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb))
        loop
          insert into public.historico_vendas_anunciantes
            (anunciante_id, cliente_id, cliente_nome, produto_nome, valor_compra)
          values (
            v_anunciante.id,
            new.customer_id,
            new.customer_name,
            coalesce(v_item->>'name', 'Produto'),
            coalesce((v_item->>'price')::numeric, 0) * coalesce((v_item->>'quantity')::numeric, 1)
          );
        end loop;
      end if;
    end if;

    -- (b) afiliado -----------------------------------------------------------------
    if new.afiliado_id is not null then
      insert into public.afiliados_indicacoes
        (afiliado_id, codigo_afiliado, cliente_id, order_id, valor_venda, comissao, status)
      values (
        new.afiliado_id,
        coalesce(new.codigo_afiliado_usado, '#0000'),
        new.customer_id,
        new.id,
        new.total,
        round(new.total * 0.10, 2),   -- 10% de comissão (mude aqui se quiser outro %)
        'pago'
      );
    end if;

  end if;

  return new;
end;
$$;

-- remove a trigger antiga separada de afiliado (agora tudo é feito em uma só)
drop trigger if exists trg_comissao_afiliado on public.orders;
drop function if exists public.registrar_comissao_afiliado();

drop trigger if exists trg_processar_pagamento_indicacao on public.orders;
create trigger trg_processar_pagamento_indicacao
  after update on public.orders
  for each row execute function public.processar_pagamento_indicacao();


-- =====================================================================================
-- 12) CONFIRMAÇÃO AUTOMÁTICA DE PAGAMENTO (pg_cron a cada 30s)
-- =====================================================================================
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
    return;
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
      continue;
    end;

    if v_response.status between 200 and 299 then
      v_mp     := v_response.content::jsonb;
      v_status := v_mp ->> 'status';

      if v_status = 'approved' then
        update public.orders set status = 'PAGO', paid_at = now() where id = v_order.id;
      elsif v_status in ('rejected', 'cancelled') then
        update public.orders set status = 'CANCELADO' where id = v_order.id;
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
    raise notice 'pg_cron não aceitou intervalo em segundos nesta versão — agendado para rodar 1x por minuto.';
  exception when others then
    raise notice 'Não consegui agendar o job automático (%). Ative a extensão "pg_cron" em Database → Extensions e rode este bloco de novo.', sqlerrm;
  end;
end $$;


-- =====================================================================================
-- 13) MESSAGES — chat vinculado a um pedido
-- =====================================================================================
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

drop policy if exists "participants read messages" on public.messages;
create policy "participants read messages" on public.messages
  for select using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

drop policy if exists "participants send messages" on public.messages;
create policy "participants send messages" on public.messages
  for insert with check (
    sender_id = auth.uid()
    and (
      public.is_admin()
      or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
    )
  );

drop policy if exists "participants update messages read status" on public.messages;
create policy "participants update messages read status" on public.messages
  for update using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when others then
  raise notice 'messages já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 14) CHAT GLOBAL
-- =====================================================================================
create table if not exists public.chat_global (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  sender_name   text not null,
  sender_role   text not null default 'client' check (sender_role in ('admin','client')),
  message_text  text,
  created_at    timestamptz not null default now()
);

alter table public.chat_global add column if not exists image_url text;
alter table public.chat_global add column if not exists sender_avatar_url text;
alter table public.chat_global add column if not exists client_id uuid;

alter table public.chat_global drop constraint if exists chat_global_texto_ou_imagem;
alter table public.chat_global
  add constraint chat_global_texto_ou_imagem check (message_text is not null or image_url is not null);

create index if not exists idx_chat_global_created_at on public.chat_global (created_at);

alter table public.chat_global enable row level security;

drop policy if exists "chat_global select authenticated" on public.chat_global;
create policy "chat_global select authenticated" on public.chat_global
  for select using (auth.role() = 'authenticated');

drop policy if exists "chat_global insert own" on public.chat_global;
create policy "chat_global insert own" on public.chat_global
  for insert with check (sender_id = auth.uid() and auth.role() = 'authenticated');

drop policy if exists "chat_global delete admin" on public.chat_global;
create policy "chat_global delete admin" on public.chat_global
  for delete using (public.is_admin());

do $$
begin
  alter publication supabase_realtime add table public.chat_global;
exception when others then
  raise notice 'chat_global já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 15) CHAT PRIVADO — conversa contínua cliente <-> admin (suporte)
-- =====================================================================================
create table if not exists public.chat_privado (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references auth.users(id) on delete cascade,
  sender_id     uuid not null references auth.users(id),
  sender_role   text not null check (sender_role in ('admin','client')),
  message_text  text,
  image_url     text,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.chat_privado add column if not exists image_url text;

create index if not exists idx_chat_privado_customer on public.chat_privado (customer_id, created_at);
create index if not exists idx_chat_privado_unread   on public.chat_privado (customer_id) where read_at is null;

alter table public.chat_privado enable row level security;

drop policy if exists "chat_privado select" on public.chat_privado;
create policy "chat_privado select" on public.chat_privado
  for select using (public.is_admin() or customer_id = auth.uid());

drop policy if exists "chat_privado insert" on public.chat_privado;
create policy "chat_privado insert" on public.chat_privado
  for insert with check (
    sender_id = auth.uid()
    and (
      (public.is_admin() and sender_role = 'admin')
      or (customer_id = auth.uid() and sender_role = 'client')
    )
  );

drop policy if exists "chat_privado update read status" on public.chat_privado;
create policy "chat_privado update read status" on public.chat_privado
  for update using (public.is_admin() or customer_id = auth.uid())
  with check (public.is_admin() or customer_id = auth.uid());

do $$
begin
  alter publication supabase_realtime add table public.chat_privado;
exception when others then
  raise notice 'chat_privado já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 16) AMIGOS
-- =====================================================================================
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

drop policy if exists "amigos insert proprio pedido" on public.amigos;
create policy "amigos insert proprio pedido" on public.amigos
  for insert with check (requester_id = auth.uid());

drop policy if exists "amigos update aceitar" on public.amigos;
create policy "amigos update aceitar" on public.amigos
  for update using (addressee_id = auth.uid() or requester_id = auth.uid())
  with check (addressee_id = auth.uid() or requester_id = auth.uid());

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


-- =====================================================================================
-- 17) MENSAGENS PRIVADAS (DM entre dois clientes)
-- =====================================================================================
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

create index if not exists idx_msgpriv_thread
  on public.mensagens_privadas (least(sender_id, receiver_id), greatest(sender_id, receiver_id), created_at);
create index if not exists idx_msgpriv_receiver_unread
  on public.mensagens_privadas (receiver_id, read_at);

alter table public.mensagens_privadas enable row level security;

drop policy if exists "mensagens_privadas select proprias" on public.mensagens_privadas;
create policy "mensagens_privadas select proprias" on public.mensagens_privadas
  for select using (sender_id = auth.uid() or receiver_id = auth.uid());

drop policy if exists "mensagens_privadas insert proprio envio" on public.mensagens_privadas;
create policy "mensagens_privadas insert proprio envio" on public.mensagens_privadas
  for insert with check (sender_id = auth.uid());

drop policy if exists "mensagens_privadas update marcar lida" on public.mensagens_privadas;
create policy "mensagens_privadas update marcar lida" on public.mensagens_privadas
  for update using (receiver_id = auth.uid()) with check (receiver_id = auth.uid());

drop policy if exists "mensagens_privadas delete proprias" on public.mensagens_privadas;
create policy "mensagens_privadas delete proprias" on public.mensagens_privadas
  for delete using (sender_id = auth.uid());

do $$
begin
  alter publication supabase_realtime add table public.mensagens_privadas;
exception when others then
  raise notice 'mensagens_privadas já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 18) AVALIAÇÕES — só quem comprou pode avaliar (garantido pela própria RLS)
-- =====================================================================================
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

drop policy if exists "avaliacoes select public" on public.avaliacoes;
create policy "avaliacoes select public" on public.avaliacoes
  for select using (true);

drop policy if exists "avaliacoes insert own purchase" on public.avaliacoes;
create policy "avaliacoes insert own purchase" on public.avaliacoes
  for insert with check (
    customer_id = auth.uid()
    and exists (
      select 1 from public.orders o
      where o.customer_id = auth.uid()
        and o.status = 'PAGO'
        and o.items @> jsonb_build_array(jsonb_build_object('productId', product_id::text))
    )
  );

drop policy if exists "avaliacoes update own" on public.avaliacoes;
create policy "avaliacoes update own" on public.avaliacoes
  for update using (customer_id = auth.uid()) with check (customer_id = auth.uid());

drop policy if exists "avaliacoes delete own or admin" on public.avaliacoes;
create policy "avaliacoes delete own or admin" on public.avaliacoes
  for delete using (customer_id = auth.uid() or public.is_admin());

create or replace function public.avaliacoes_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_avaliacoes_updated_at on public.avaliacoes;
create trigger trg_avaliacoes_updated_at
  before update on public.avaliacoes
  for each row execute function public.avaliacoes_set_updated_at();


-- =====================================================================================
-- 19) SORTEIOS
-- =====================================================================================
create table if not exists public.sorteios (
  id                  uuid primary key default gen_random_uuid(),
  titulo              text not null,
  premio              text not null,
  dias                integer,
  data_sorteio        date not null,
  status              text not null default 'aberto' check (status in ('aberto','finalizado')),
  ganhador_profile_id uuid references public.profiles(id) on delete set null,
  ganhador_codigo     text,
  ganhador_nome       text,
  created_at          timestamptz not null default now(),
  finalizado_em       timestamptz
);

alter table public.sorteios enable row level security;

drop policy if exists "sorteios_select_public" on public.sorteios;
create policy "sorteios_select_public" on public.sorteios
  for select using (true);

drop policy if exists "sorteios_admin_all" on public.sorteios;
create policy "sorteios_admin_all" on public.sorteios
  for all using (public.is_admin()) with check (public.is_admin());

-- lista clientes reais (com código e com compra confirmada) pra alimentar a roleta
create or replace function public.sorteio_listar_participantes()
returns table (codigo_cliente text, nome text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
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

create or replace function public.sorteio_definir_ganhador(p_sorteio_id uuid, p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile record;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas administradores podem definir o ganhador.';
  end if;

  select id, full_name into v_profile
  from public.profiles
  where codigo_cliente = p_codigo;

  if v_profile.id is null then
    raise exception 'Cliente com código % não encontrado.', p_codigo;
  end if;

  update public.sorteios
  set status              = 'finalizado',
      ganhador_profile_id = v_profile.id,
      ganhador_codigo     = p_codigo,
      ganhador_nome       = coalesce(v_profile.full_name, 'Cliente'),
      finalizado_em       = now()
  where id = p_sorteio_id;
end;
$$;

grant execute on function public.sorteio_definir_ganhador(uuid, text) to authenticated;


-- =====================================================================================
-- 20) TICKETS — central de suporte
-- =====================================================================================
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
create index if not exists tickets_status_idx      on public.tickets(status);

create table if not exists public.ticket_mensagens (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.tickets(id) on delete cascade,
  sender_role  text not null check (sender_role in ('client','admin')),
  message_text text not null,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists ticket_mensagens_ticket_id_idx on public.ticket_mensagens(ticket_id);

create or replace function public.tickets_touch_updated_at()
returns trigger language plpgsql as $$
begin
  update public.tickets set updated_at = now() where id = new.ticket_id;
  return new;
end;
$$;

drop trigger if exists trg_ticket_mensagens_touch on public.ticket_mensagens;
create trigger trg_ticket_mensagens_touch
  after insert on public.ticket_mensagens
  for each row execute function public.tickets_touch_updated_at();

alter table public.tickets          enable row level security;
alter table public.ticket_mensagens enable row level security;

drop policy if exists "tickets_select_own_or_admin" on public.tickets;
create policy "tickets_select_own_or_admin" on public.tickets
  for select using (customer_id = auth.uid() or public.is_admin());

drop policy if exists "tickets_insert_own" on public.tickets;
create policy "tickets_insert_own" on public.tickets
  for insert with check (customer_id = auth.uid());

drop policy if exists "tickets_update_own_or_admin" on public.tickets;
create policy "tickets_update_own_or_admin" on public.tickets
  for update using (customer_id = auth.uid() or public.is_admin());

drop policy if exists "ticket_mensagens_select" on public.ticket_mensagens;
create policy "ticket_mensagens_select" on public.ticket_mensagens
  for select using (
    public.is_admin()
    or exists (select 1 from public.tickets t where t.id = ticket_mensagens.ticket_id and t.customer_id = auth.uid())
  );

drop policy if exists "ticket_mensagens_insert" on public.ticket_mensagens;
create policy "ticket_mensagens_insert" on public.ticket_mensagens
  for insert with check (
    (public.is_admin() and sender_role = 'admin')
    or exists (
      select 1 from public.tickets t
      where t.id = ticket_mensagens.ticket_id
        and t.customer_id = auth.uid()
        and sender_role = 'client'
    )
  );

drop policy if exists "ticket_mensagens_update" on public.ticket_mensagens;
create policy "ticket_mensagens_update" on public.ticket_mensagens
  for update using (
    public.is_admin()
    or exists (select 1 from public.tickets t where t.id = ticket_mensagens.ticket_id and t.customer_id = auth.uid())
  );

do $$
begin
  alter publication supabase_realtime add table public.ticket_mensagens;
exception when others then
  raise notice 'ticket_mensagens já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 21) PRODUCT_VIEWS — o que cada cliente já olhou (usado na aba "Contas" do admin)
-- =====================================================================================
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

drop policy if exists "product_views admin select" on public.product_views;
create policy "product_views admin select" on public.product_views
  for select using (public.is_admin());

drop policy if exists "product_views insert own" on public.product_views;
create policy "product_views insert own" on public.product_views
  for insert with check (cliente_id = auth.uid());


-- =====================================================================================
-- 22) STORAGE — buckets públicos de imagem
-- =====================================================================================
insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('site-assets', 'site-assets', true)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('chat-uploads', 'chat-uploads', true)
  on conflict (id) do nothing;

drop policy if exists "public read product-images" on storage.objects;
create policy "public read product-images" on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists "public read site-assets" on storage.objects;
create policy "public read site-assets" on storage.objects
  for select using (bucket_id = 'site-assets');

drop policy if exists "chat-uploads leitura publica" on storage.objects;
create policy "chat-uploads leitura publica" on storage.objects
  for select using (bucket_id = 'chat-uploads');

drop policy if exists "admin upload product-images" on storage.objects;
create policy "admin upload product-images" on storage.objects
  for insert with check (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin update product-images" on storage.objects;
create policy "admin update product-images" on storage.objects
  for update using (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin delete product-images" on storage.objects;
create policy "admin delete product-images" on storage.objects
  for delete using (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin upload site-assets" on storage.objects;
create policy "admin upload site-assets" on storage.objects
  for insert with check (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "admin update site-assets" on storage.objects;
create policy "admin update site-assets" on storage.objects
  for update using (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "admin delete site-assets" on storage.objects;
create policy "admin delete site-assets" on storage.objects
  for delete using (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "chat-uploads upload autenticado" on storage.objects;
create policy "chat-uploads upload autenticado" on storage.objects
  for insert to authenticated with check (bucket_id = 'chat-uploads');

drop policy if exists "chat-uploads update autor" on storage.objects;
create policy "chat-uploads update autor" on storage.objects
  for update to authenticated using (bucket_id = 'chat-uploads' and owner = auth.uid());


-- =====================================================================================
-- 23) MIGRAÇÃO — converte códigos de afiliado antigos (ex: "MARIA482") para #0000
-- =====================================================================================
-- Rode só uma vez; depois disso ela não encontra mais nada pra converter.
-- Os clientes afetados precisam ser avisados do novo código (o admin pode usar o
-- botão "↻ Reenviar código" no painel).
-- =====================================================================================
do $$
declare
  r record;
  v_novo text;
begin
  for r in
    select id, codigo_afiliado from public.profiles
    where is_afiliado = true
      and codigo_afiliado is not null
      and codigo_afiliado !~ '^#[0-9]{4}$'
  loop
    v_novo := public.gerar_codigo_indicacao();
    update public.profiles set codigo_afiliado = v_novo where id = r.id;
    raise notice 'Código de afiliado convertido: % -> %', r.codigo_afiliado, v_novo;
  end loop;
end $$;

-- Garante que todo código de anunciante também siga o formato #0000
do $$
declare
  r record;
  v_novo text;
begin
  for r in
    select id, codigo from public.anunciantes where codigo !~ '^#[0-9]{4}$'
  loop
    v_novo := public.gerar_codigo_indicacao();
    update public.anunciantes set codigo = v_novo where id = r.id;
    raise notice 'Código de anunciante convertido: % -> %', r.codigo, v_novo;
  end loop;
end $$;


-- =====================================================================================
-- 24) PASSOS MANUAIS FINAIS (fazer uma vez só)
-- =====================================================================================
--
-- A) TOKEN DO MERCADO PAGO
--    Pegue seu Access Token de produção em:
--      Mercado Pago → Seu negócio → Configurações → Gestão e administração →
--      Credenciais → Credenciais de produção → Access Token
--
--    Depois rode (trocando pelo SEU token):
--
--      select vault.create_secret('APP_USR-SEU-TOKEN-AQUI', 'mp_access_token');
--
--    Se já existir e você quiser trocar:
--
--      select vault.update_secret(
--        (select id from vault.secrets where name = 'mp_access_token'),
--        'APP_USR-NOVO-TOKEN-AQUI'
--      );
--
--
-- B) VIRAR ADMINISTRADOR
--    1. Crie sua conta normalmente pelo site (botão "Login" → "Criar conta").
--    2. Depois rode isto, trocando pelo e-mail que você cadastrou:
--
--      update public.profiles set role = 'admin'
--      where id = (select id from auth.users where email = 'SEU-EMAIL@AQUI.com');
--
--    A partir daí essa conta entra em /#admin. Contas sem role = 'admin' são
--    bloqueadas e deslogadas automaticamente ao tentar.
--
--
-- C) CONFERIR SE ESTÁ TUDO NO LUGAR (opcional)
--
--      select routine_name from information_schema.routines
--      where routine_schema = 'public' order by routine_name;
--
--      select tablename from pg_tables where schemaname = 'public' order by tablename;
--
--      -- deve retornar exatamente 1 linha (uma única versão de criar_pix):
--      select count(*) from pg_proc p
--      join pg_namespace n on n.oid = p.pronamespace
--      where n.nspname = 'public' and p.proname = 'criar_pix';
--
---- =====================================================================================
-- PATCH — necessário para o botão "Afiliar Conta" (cria um ticket em nome do cliente)
-- =====================================================================================
-- A policy de INSERT em "tickets" só permitia customer_id = auth.uid(), ou seja,
-- só o próprio cliente podia abrir um ticket para si mesmo. Agora o admin também
-- precisa poder criar um ticket EM NOME do cliente (o ticket "Programa de Afiliados!").
-- Rode isto uma vez no SQL Editor do Supabase:
-- =====================================================================================

drop policy if exists "tickets_insert_own" on public.tickets;
create policy "tickets_insert_own" on public.tickets
  for insert with check (customer_id = auth.uid() or public.is_admin());

-- =====================================================================================
-- PATCH — reforço de permissões em product_views
-- =====================================================================================
-- Rode isso uma vez no SQL Editor do Supabase. Ele não apaga nada, só garante que:
--   1. O cliente logado também consegue LER as próprias visualizações (hoje só o
--      admin podia via RLS — não deveria ser a causa do bug, mas fecha essa brecha).
--   2. As permissões de tabela (GRANT) para authenticated estão explícitas, caso o
--      projeto tenha em algum momento perdido os grants padrão do Supabase.
-- =====================================================================================

drop policy if exists "product_views select own" on public.product_views;
create policy "product_views select own" on public.product_views
  for select using (cliente_id = auth.uid() or public.is_admin());

grant select, insert on public.product_views to authenticated;

-- Confirmação rápida: rode isto depois e veja se aparecem linhas
-- (troque o e-mail pelo da conta de teste que você usou como cliente).
--
-- select pv.product_nome, pv.created_at, p.email
-- from public.product_views pv
-- join public.profiles p on p.id = pv.cliente_id
-- where p.email = 'EMAIL-DA-CONTA-CLIENTE-DE-TESTE@AQUI.com'
-- order by pv.created_at desc;

-- =====================================================================================
-- NOVASTORE — SCRIPT SQL SUPREMO (v3, consolidado)
-- =====================================================================================
-- Este arquivo substitui TODOS os scripts anteriores. Ele contém, em ordem correta
-- de dependência, tudo que o site precisa para funcionar 100%:
--
--   1.  Extensões (pgcrypto, http, pg_cron)
--   2.  profiles + is_admin() + criação automática de perfil + código de cliente
--   3.  products
--   4.  site_settings (aparência, tema, efeitos)
--   5.  orders
--   6.  anunciantes + histórico de vendas
--   7.  Programa de afiliados (código #0000, indicações, comissões)
--   8.  criar_pix() — VERSÃO ÚNICA E DEFINITIVA (Pix + código + desconto de 10%)
--   9.  Confirmação automática de pagamento (Mercado Pago + pg_cron)
--   10. messages (chat por pedido)
--   11. chat_global / chat_privado
--   12. amigos / mensagens_privadas
--   13. avaliacoes
--   14. sorteios
--   15. tickets (central de suporte)
--   16. product_views
--   17. Storage (buckets de imagem)
--   18. Passos manuais finais (token do Mercado Pago + virar admin)
--
-- É SEGURO rodar este arquivo inteiro de uma vez, quantas vezes quiser, em um projeto
-- que já tem dados: tudo usa IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY IF EXISTS
-- e NENHUM comando apaga dados existentes.
--
-- REGRAS DE NEGÓCIO DESTA VERSÃO:
--   • Todo código de indicação (anunciante OU afiliado) tem o formato #0000
--     (o caractere "#" seguido de exatamente 4 dígitos).
--   • Um código de anunciante e um de afiliado nunca podem ser iguais, porque os
--     dois são digitados no mesmo campo do checkout.
--   • Usar um código dá 10% DE DESCONTO em compras a partir de R$ 80,00.
--   • Quando o pedido é confirmado como PAGO, o afiliado ganha 10% de comissão.
-- =====================================================================================


-- =====================================================================================
-- 1) EXTENSÕES
-- =====================================================================================
create extension if not exists pgcrypto;
create extension if not exists http with schema extensions;

do $$
begin
  create extension if not exists pg_cron with schema extensions;
exception when others then
  raise notice 'pg_cron não pôde ser criado automaticamente (%). Se a confirmação automática de pagamento não funcionar, ative a extensão "pg_cron" em Database → Extensions no painel do Supabase.', sqlerrm;
end $$;


-- =====================================================================================
-- 2) PROFILES — perfil de cada usuário, base de todo o controle de permissão
-- =====================================================================================
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  email       text,
  phone       text,
  role        text not null default 'client' check (role in ('admin','client')),
  created_at  timestamptz default now()
);

-- colunas que foram sendo adicionadas ao longo do tempo
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists codigo_cliente text;
alter table public.profiles add column if not exists tem_cupom_proxima_compra boolean not null default false;
alter table public.profiles add column if not exists is_afiliado boolean not null default false;
alter table public.profiles add column if not exists codigo_afiliado text;

-- índices únicos (como índice, e não constraint, pra poder usar IF NOT EXISTS)
create unique index if not exists profiles_codigo_cliente_key
  on public.profiles (codigo_cliente) where codigo_cliente is not null;
create unique index if not exists profiles_codigo_afiliado_key
  on public.profiles (codigo_afiliado) where codigo_afiliado is not null;

alter table public.profiles enable row level security;

-- -------------------------------------------------------------------------------------
-- is_admin(): usada em quase todas as policies. É SECURITY DEFINER pra não cair em
-- recursão de RLS ao consultar a própria tabela profiles dentro de uma policy dela.
-- -------------------------------------------------------------------------------------
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

-- Leitura: o dono lê o próprio perfil; o admin lê todos.
-- Além disso, qualquer usuário logado precisa conseguir ler nome/avatar dos outros
-- (busca de amigos, chat global, painel). Como o Postgres não filtra por COLUNA em RLS,
-- liberamos o SELECT para autenticados — não há dado sensível em profiles além do
-- e-mail/telefone, que o site nunca exibe para terceiros.
drop policy if exists "users read own profile" on public.profiles;
drop policy if exists "profiles select" on public.profiles;
create policy "profiles select" on public.profiles
  for select using (auth.role() = 'authenticated' or public.is_admin());

drop policy if exists "users update own profile" on public.profiles;
drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles
  for update using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

-- Não existe policy de INSERT: o perfil nasce pela trigger abaixo (SECURITY DEFINER).

-- -------------------------------------------------------------------------------------
-- Código de cliente (NS-00000) — usado como "número da sorte" nos sorteios
-- -------------------------------------------------------------------------------------
create or replace function public.gerar_codigo_cliente()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  novo_codigo text;
  ja_existe   boolean;
begin
  loop
    novo_codigo := 'NS-' || lpad(floor(random() * 100000)::int::text, 5, '0');
    select exists(select 1 from public.profiles where codigo_cliente = novo_codigo) into ja_existe;
    exit when not ja_existe;
  end loop;
  return novo_codigo;
end;
$$;

create or replace function public.trg_set_codigo_cliente()
returns trigger
language plpgsql
security definer
set search_path = public
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

-- preenche o código de quem já tinha conta antes desta regra existir
do $$
declare r record;
begin
  for r in select id from public.profiles where codigo_cliente is null loop
    update public.profiles set codigo_cliente = public.gerar_codigo_cliente() where id = r.id;
  end loop;
end $$;

-- -------------------------------------------------------------------------------------
-- Cria o profile automaticamente quando alguém se cadastra (supabase.auth.signUp)
-- -------------------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, avatar_url, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'avatar_url',
    new.email,
    'client'
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- preenche o e-mail de quem já tinha conta antes da coluna existir
update public.profiles p
set email = u.email
from auth.users u
where u.id = p.id and p.email is null;


-- =====================================================================================
-- 3) PRODUCTS
-- =====================================================================================
create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  slug         text,
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
create index if not exists idx_products_active   on public.products (active);

alter table public.products enable row level security;

drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products
  for select using (active = true or public.is_admin());

drop policy if exists "admin full access products" on public.products;
create policy "admin full access products" on public.products
  for all using (public.is_admin()) with check (public.is_admin());


-- =====================================================================================
-- 4) SITE_SETTINGS — banner, fundo, tema de cores e efeitos
-- =====================================================================================
create table if not exists public.site_settings (
  id                   int primary key default 1,
  hero_image_url       text,
  hero_overlay         numeric not null default 0.35,
  background_image_url text,
  background_overlay   numeric not null default 0.85,
  updated_at           timestamptz not null default now()
);

alter table public.site_settings add column if not exists theme_primary    text not null default '#7c5cff';
alter table public.site_settings add column if not exists theme_accent     text not null default '#00e6a8';
alter table public.site_settings add column if not exists effect_lightning boolean not null default false;
alter table public.site_settings add column if not exists updated_at       timestamptz not null default now();

insert into public.site_settings (id) values (1) on conflict (id) do nothing;

alter table public.site_settings enable row level security;

-- a aparência precisa ser lida por visitantes não logados
drop policy if exists "public read settings"        on public.site_settings;
drop policy if exists "site_settings select public" on public.site_settings;
create policy "site_settings select public" on public.site_settings
  for select using (true);

drop policy if exists "admin write settings"      on public.site_settings;
drop policy if exists "site_settings upsert admin" on public.site_settings;
create policy "site_settings upsert admin" on public.site_settings
  for insert with check (public.is_admin());

drop policy if exists "site_settings update admin" on public.site_settings;
create policy "site_settings update admin" on public.site_settings
  for update using (public.is_admin()) with check (public.is_admin());


-- =====================================================================================
-- 5) ORDERS — pedidos + Pix
-- =====================================================================================
create table if not exists public.orders (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid references auth.users(id),
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

alter table public.orders add column if not exists customer_id uuid references auth.users(id);
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

-- indicação / desconto
alter table public.orders add column if not exists anunciante_codigo text;
alter table public.orders add column if not exists cupom_usado boolean not null default false;
alter table public.orders add column if not exists desconto_aplicado numeric not null default 0;
alter table public.orders add column if not exists afiliado_id uuid references public.profiles(id) on delete set null;
alter table public.orders add column if not exists codigo_afiliado_usado text;

create index if not exists idx_orders_customer_id on public.orders (customer_id);
create index if not exists idx_orders_status      on public.orders (status);
create index if not exists idx_orders_afiliado    on public.orders (afiliado_id);

alter table public.orders enable row level security;

drop policy if exists "admin can view orders"    on public.orders;
drop policy if exists "customers read own orders" on public.orders;
drop policy if exists "orders select"            on public.orders;
create policy "orders select" on public.orders
  for select using (public.is_admin() or auth.uid() = customer_id);

drop policy if exists "admin can update orders" on public.orders;
drop policy if exists "orders update"           on public.orders;
create policy "orders update" on public.orders
  for update using (public.is_admin());

-- Não há policy de INSERT: pedidos só nascem dentro de criar_pix() (SECURITY DEFINER).


-- =====================================================================================
-- 6) ANUNCIANTES — códigos de indicação no formato #0000
-- =====================================================================================
create table if not exists public.anunciantes (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  codigo       text not null unique,
  total_vendas integer not null default 0,
  created_at   timestamptz not null default now()
);

alter table public.anunciantes enable row level security;

-- qualquer cliente logado pode validar um código no checkout
drop policy if exists "anunciantes select authenticated" on public.anunciantes;
create policy "anunciantes select authenticated" on public.anunciantes
  for select using (auth.role() = 'authenticated');

drop policy if exists "anunciantes admin insert" on public.anunciantes;
create policy "anunciantes admin insert" on public.anunciantes
  for insert with check (public.is_admin());

drop policy if exists "anunciantes admin update" on public.anunciantes;
create policy "anunciantes admin update" on public.anunciantes
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "anunciantes admin delete" on public.anunciantes;
create policy "anunciantes admin delete" on public.anunciantes
  for delete using (public.is_admin());

-- -------------------------------------------------------------------------------------
-- Histórico de vendas feitas com cada código de anunciante
-- -------------------------------------------------------------------------------------
create table if not exists public.historico_vendas_anunciantes (
  id             uuid primary key default gen_random_uuid(),
  anunciante_id  uuid not null references public.anunciantes(id) on delete cascade,
  cliente_id     uuid references auth.users(id),
  cliente_nome   text,
  produto_nome   text not null,
  valor_compra   numeric not null,
  created_at     timestamptz not null default now()
);

create index if not exists idx_historico_anunciante
  on public.historico_vendas_anunciantes (anunciante_id, created_at desc);

alter table public.historico_vendas_anunciantes enable row level security;

drop policy if exists "historico admin select" on public.historico_vendas_anunciantes;
create policy "historico admin select" on public.historico_vendas_anunciantes
  for select using (public.is_admin());


-- =====================================================================================
-- 7) PROGRAMA DE AFILIADOS
-- =====================================================================================
create table if not exists public.afiliados_indicacoes (
  id              uuid primary key default gen_random_uuid(),
  afiliado_id     uuid not null references public.profiles(id) on delete cascade,
  codigo_afiliado text not null,
  cliente_id      uuid references public.profiles(id) on delete set null,
  order_id        uuid references public.orders(id) on delete set null,
  valor_venda     numeric not null default 0,
  comissao        numeric not null default 0,
  status          text not null default 'pendente' check (status in ('pendente','pago')),
  created_at      timestamptz not null default now()
);

create index if not exists idx_afiliados_indicacoes_afiliado
  on public.afiliados_indicacoes (afiliado_id, created_at desc);

alter table public.afiliados_indicacoes enable row level security;

drop policy if exists "afiliado le suas indicacoes" on public.afiliados_indicacoes;
create policy "afiliado le suas indicacoes" on public.afiliados_indicacoes
  for select using (auth.uid() = afiliado_id or public.is_admin());

-- -------------------------------------------------------------------------------------
-- Gerador de código #0000 que NUNCA colide com um anunciante nem com outro afiliado.
-- O site chama isso pelo front, mas deixar a função aqui garante que qualquer
-- código gerado direto no banco siga a mesma regra.
-- -------------------------------------------------------------------------------------
create or replace function public.gerar_codigo_indicacao()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo    text;
  v_tentativas int := 0;
begin
  loop
    v_codigo := '#' || lpad(floor(random() * 10000)::int::text, 4, '0');

    exit when not exists (select 1 from public.anunciantes where codigo = v_codigo)
          and not exists (select 1 from public.profiles   where codigo_afiliado = v_codigo);

    v_tentativas := v_tentativas + 1;
    if v_tentativas > 200 then
      raise exception 'Não foi possível gerar um código de indicação livre (todos os 10.000 códigos #0000 parecem estar em uso).';
    end if;
  end loop;

  return v_codigo;
end;
$$;

grant execute on function public.gerar_codigo_indicacao() to authenticated;

-- -------------------------------------------------------------------------------------
-- Afiliar uma conta: gera o código e marca o perfil. Só admin pode chamar.
-- (O site também faz isso direto por UPDATE; esta função é o caminho seguro.)
-- -------------------------------------------------------------------------------------
create or replace function public.afiliar_cliente(p_cliente_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas administradores podem afiliar contas.';
  end if;

  select codigo_afiliado into v_codigo
  from public.profiles where id = p_cliente_id and is_afiliado = true;

  if v_codigo is not null then
    return v_codigo; -- já é afiliado, devolve o código existente
  end if;

  v_codigo := public.gerar_codigo_indicacao();

  update public.profiles
  set is_afiliado = true, codigo_afiliado = v_codigo
  where id = p_cliente_id;

  return v_codigo;
end;
$$;

grant execute on function public.afiliar_cliente(uuid) to authenticated;


-- =====================================================================================
-- 8) MERCADO PAGO — token guardado no Vault
-- =====================================================================================
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


-- =====================================================================================
-- 9) get_order_status — o site consulta isso pra saber se o Pix caiu
-- =====================================================================================
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


-- =====================================================================================
-- 10) criar_pix() — VERSÃO ÚNICA E DEFINITIVA
-- =====================================================================================
-- IMPORTANTE: versões antigas desta função (com 3, 4 e 6 parâmetros) são REMOVIDAS
-- abaixo. Se duas sobrecargas coexistirem, o PostgREST não consegue decidir qual
-- chamar e o site passa a receber o erro "Could not choose the best candidate function".
-- =====================================================================================
drop function if exists public.criar_pix(text, text, jsonb);
drop function if exists public.criar_pix(text, text, jsonb, uuid);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text, boolean);
drop function if exists public.criar_pix(text, text, jsonb, uuid, text, uuid, boolean);

create or replace function public.criar_pix(
  p_name              text,
  p_email             text,
  p_items             jsonb,
  p_customer_id       uuid default null,
  p_anunciante_codigo text default null,
  p_afiliado_id       uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token           text;
  v_subtotal        numeric;
  v_total           numeric;
  v_order_id        uuid;
  v_expires_at      timestamptz := now() + interval '30 minutes';
  v_first_name      text;
  v_last_name       text;
  v_payload         jsonb;
  v_response        http_response;
  v_mp              jsonb;
  v_qr_code         text;
  v_qr_base64       text;
  v_mp_id           text;
  v_codigo          text;
  v_codigo_afiliado text;
  v_desconto        numeric := 0;
  v_tem_indicacao   boolean := false;
  -- >>> regra de negócio: 10% de desconto em compras a partir de R$ 80,00 <<<
  c_desconto_pct    constant numeric := 0.10;
  c_valor_minimo    constant numeric := 80;
begin
  if p_name is null or p_email is null or p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('error', 'Dados incompletos para gerar o Pix.');
  end if;

  select coalesce(sum((item->>'price')::numeric * coalesce((item->>'quantity')::numeric, 1)), 0)
  into v_subtotal
  from jsonb_array_elements(p_items) as item;

  if v_subtotal <= 0 then
    return jsonb_build_object('error', 'Valor do pedido inválido.');
  end if;

  -- ---- valida o código de ANUNCIANTE, se informado -----------------------------------
  v_codigo := nullif(trim(p_anunciante_codigo), '');
  if v_codigo is not null then
    if not exists (select 1 from public.anunciantes where codigo = v_codigo) then
      return jsonb_build_object('error', 'Código de anunciante inválido.');
    end if;
    v_tem_indicacao := true;
  end if;

  -- ---- valida o código de AFILIADO, se informado --------------------------------------
  if p_afiliado_id is not null then
    select codigo_afiliado into v_codigo_afiliado
    from public.profiles
    where id = p_afiliado_id and is_afiliado = true;

    if v_codigo_afiliado is null then
      return jsonb_build_object('error', 'Código de afiliado inválido.');
    end if;

    -- ninguém pode usar o próprio código de afiliado pra se dar desconto
    if p_customer_id is not null and p_customer_id = p_afiliado_id then
      return jsonb_build_object('error', 'Você não pode usar o seu próprio código de afiliado.');
    end if;

    v_tem_indicacao := true;
  end if;

  -- ---- aplica os 10% se houver indicação e o subtotal atingir o mínimo ----------------
  if v_tem_indicacao and v_subtotal >= c_valor_minimo then
    v_desconto := round(v_subtotal * c_desconto_pct, 2);
  end if;

  v_total := greatest(v_subtotal - v_desconto, 0.01);

  v_token := public.mp_get_token();
  if v_token is null or v_token = '' then
    return jsonb_build_object('error', 'Token do Mercado Pago não configurado. Cadastre o segredo "mp_access_token" no Vault do Supabase.');
  end if;

  insert into public.orders (
    customer_name, customer_email, customer_id, items, total, status, expires_at,
    anunciante_codigo, cupom_usado, desconto_aplicado,
    afiliado_id, codigo_afiliado_usado
  )
  values (
    p_name, p_email, p_customer_id, p_items, v_total, 'PENDENTE', v_expires_at,
    v_codigo, (v_desconto > 0), v_desconto,
    p_afiliado_id, v_codigo_afiliado
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
      coalesce((v_response.content::jsonb ->> 'message'),
               'Erro ao gerar cobrança Pix no Mercado Pago (status ' || v_response.status || ').')
    );
  end if;

  v_mp        := v_response.content::jsonb;
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
    'orderId',          v_order_id,
    'qrCode',           v_qr_code,
    'qrCodeBase64',     v_qr_base64,
    'expiresAt',        v_expires_at,
    'subtotal',         v_subtotal,
    'total',            v_total,
    'descontoAplicado', v_desconto
  );
end;
$$;

revoke all on function public.criar_pix(text, text, jsonb, uuid, text, uuid) from public;
grant execute on function public.criar_pix(text, text, jsonb, uuid, text, uuid) to anon, authenticated;


-- =====================================================================================
-- 11) TRIGGER — o que acontece quando um pedido vira PAGO
-- =====================================================================================
--   a) código de anunciante: +1 venda, registra no histórico
--   b) código de afiliado:   gera a comissão de 10% pro afiliado
-- =====================================================================================
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

    -- (a) anunciante ---------------------------------------------------------------
    if new.anunciante_codigo is not null then
      select * into v_anunciante from public.anunciantes where codigo = new.anunciante_codigo;

      if found then
        update public.anunciantes
        set total_vendas = total_vendas + 1
        where id = v_anunciante.id;

        for v_item in select * from jsonb_array_elements(coalesce(new.items, '[]'::jsonb))
        loop
          insert into public.historico_vendas_anunciantes
            (anunciante_id, cliente_id, cliente_nome, produto_nome, valor_compra)
          values (
            v_anunciante.id,
            new.customer_id,
            new.customer_name,
            coalesce(v_item->>'name', 'Produto'),
            coalesce((v_item->>'price')::numeric, 0) * coalesce((v_item->>'quantity')::numeric, 1)
          );
        end loop;
      end if;
    end if;

    -- (b) afiliado -----------------------------------------------------------------
    if new.afiliado_id is not null then
      insert into public.afiliados_indicacoes
        (afiliado_id, codigo_afiliado, cliente_id, order_id, valor_venda, comissao, status)
      values (
        new.afiliado_id,
        coalesce(new.codigo_afiliado_usado, '#0000'),
        new.customer_id,
        new.id,
        new.total,
        round(new.total * 0.10, 2),   -- 10% de comissão (mude aqui se quiser outro %)
        'pago'
      );
    end if;

  end if;

  return new;
end;
$$;

-- remove a trigger antiga separada de afiliado (agora tudo é feito em uma só)
drop trigger if exists trg_comissao_afiliado on public.orders;
drop function if exists public.registrar_comissao_afiliado();

drop trigger if exists trg_processar_pagamento_indicacao on public.orders;
create trigger trg_processar_pagamento_indicacao
  after update on public.orders
  for each row execute function public.processar_pagamento_indicacao();


-- =====================================================================================
-- 12) CONFIRMAÇÃO AUTOMÁTICA DE PAGAMENTO (pg_cron a cada 30s)
-- =====================================================================================
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
    return;
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
      continue;
    end;

    if v_response.status between 200 and 299 then
      v_mp     := v_response.content::jsonb;
      v_status := v_mp ->> 'status';

      if v_status = 'approved' then
        update public.orders set status = 'PAGO', paid_at = now() where id = v_order.id;
      elsif v_status in ('rejected', 'cancelled') then
        update public.orders set status = 'CANCELADO' where id = v_order.id;
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
    raise notice 'pg_cron não aceitou intervalo em segundos nesta versão — agendado para rodar 1x por minuto.';
  exception when others then
    raise notice 'Não consegui agendar o job automático (%). Ative a extensão "pg_cron" em Database → Extensions e rode este bloco de novo.', sqlerrm;
  end;
end $$;


-- =====================================================================================
-- 13) MESSAGES — chat vinculado a um pedido
-- =====================================================================================
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

drop policy if exists "participants read messages" on public.messages;
create policy "participants read messages" on public.messages
  for select using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

drop policy if exists "participants send messages" on public.messages;
create policy "participants send messages" on public.messages
  for insert with check (
    sender_id = auth.uid()
    and (
      public.is_admin()
      or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
    )
  );

drop policy if exists "participants update messages read status" on public.messages;
create policy "participants update messages read status" on public.messages
  for update using (
    public.is_admin()
    or exists (select 1 from public.orders o where o.id = messages.order_id and o.customer_id = auth.uid())
  );

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when others then
  raise notice 'messages já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 14) CHAT GLOBAL
-- =====================================================================================
create table if not exists public.chat_global (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  sender_name   text not null,
  sender_role   text not null default 'client' check (sender_role in ('admin','client')),
  message_text  text,
  created_at    timestamptz not null default now()
);

alter table public.chat_global add column if not exists image_url text;
alter table public.chat_global add column if not exists sender_avatar_url text;
alter table public.chat_global add column if not exists client_id uuid;

alter table public.chat_global drop constraint if exists chat_global_texto_ou_imagem;
alter table public.chat_global
  add constraint chat_global_texto_ou_imagem check (message_text is not null or image_url is not null);

create index if not exists idx_chat_global_created_at on public.chat_global (created_at);

alter table public.chat_global enable row level security;

drop policy if exists "chat_global select authenticated" on public.chat_global;
create policy "chat_global select authenticated" on public.chat_global
  for select using (auth.role() = 'authenticated');

drop policy if exists "chat_global insert own" on public.chat_global;
create policy "chat_global insert own" on public.chat_global
  for insert with check (sender_id = auth.uid() and auth.role() = 'authenticated');

drop policy if exists "chat_global delete admin" on public.chat_global;
create policy "chat_global delete admin" on public.chat_global
  for delete using (public.is_admin());

do $$
begin
  alter publication supabase_realtime add table public.chat_global;
exception when others then
  raise notice 'chat_global já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 15) CHAT PRIVADO — conversa contínua cliente <-> admin (suporte)
-- =====================================================================================
create table if not exists public.chat_privado (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references auth.users(id) on delete cascade,
  sender_id     uuid not null references auth.users(id),
  sender_role   text not null check (sender_role in ('admin','client')),
  message_text  text,
  image_url     text,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.chat_privado add column if not exists image_url text;

create index if not exists idx_chat_privado_customer on public.chat_privado (customer_id, created_at);
create index if not exists idx_chat_privado_unread   on public.chat_privado (customer_id) where read_at is null;

alter table public.chat_privado enable row level security;

drop policy if exists "chat_privado select" on public.chat_privado;
create policy "chat_privado select" on public.chat_privado
  for select using (public.is_admin() or customer_id = auth.uid());

drop policy if exists "chat_privado insert" on public.chat_privado;
create policy "chat_privado insert" on public.chat_privado
  for insert with check (
    sender_id = auth.uid()
    and (
      (public.is_admin() and sender_role = 'admin')
      or (customer_id = auth.uid() and sender_role = 'client')
    )
  );

drop policy if exists "chat_privado update read status" on public.chat_privado;
create policy "chat_privado update read status" on public.chat_privado
  for update using (public.is_admin() or customer_id = auth.uid())
  with check (public.is_admin() or customer_id = auth.uid());

do $$
begin
  alter publication supabase_realtime add table public.chat_privado;
exception when others then
  raise notice 'chat_privado já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 16) AMIGOS
-- =====================================================================================
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

drop policy if exists "amigos insert proprio pedido" on public.amigos;
create policy "amigos insert proprio pedido" on public.amigos
  for insert with check (requester_id = auth.uid());

drop policy if exists "amigos update aceitar" on public.amigos;
create policy "amigos update aceitar" on public.amigos
  for update using (addressee_id = auth.uid() or requester_id = auth.uid())
  with check (addressee_id = auth.uid() or requester_id = auth.uid());

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


-- =====================================================================================
-- 17) MENSAGENS PRIVADAS (DM entre dois clientes)
-- =====================================================================================
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

create index if not exists idx_msgpriv_thread
  on public.mensagens_privadas (least(sender_id, receiver_id), greatest(sender_id, receiver_id), created_at);
create index if not exists idx_msgpriv_receiver_unread
  on public.mensagens_privadas (receiver_id, read_at);

alter table public.mensagens_privadas enable row level security;

drop policy if exists "mensagens_privadas select proprias" on public.mensagens_privadas;
create policy "mensagens_privadas select proprias" on public.mensagens_privadas
  for select using (sender_id = auth.uid() or receiver_id = auth.uid());

drop policy if exists "mensagens_privadas insert proprio envio" on public.mensagens_privadas;
create policy "mensagens_privadas insert proprio envio" on public.mensagens_privadas
  for insert with check (sender_id = auth.uid());

drop policy if exists "mensagens_privadas update marcar lida" on public.mensagens_privadas;
create policy "mensagens_privadas update marcar lida" on public.mensagens_privadas
  for update using (receiver_id = auth.uid()) with check (receiver_id = auth.uid());

drop policy if exists "mensagens_privadas delete proprias" on public.mensagens_privadas;
create policy "mensagens_privadas delete proprias" on public.mensagens_privadas
  for delete using (sender_id = auth.uid());

do $$
begin
  alter publication supabase_realtime add table public.mensagens_privadas;
exception when others then
  raise notice 'mensagens_privadas já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 18) AVALIAÇÕES — só quem comprou pode avaliar (garantido pela própria RLS)
-- =====================================================================================
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

drop policy if exists "avaliacoes select public" on public.avaliacoes;
create policy "avaliacoes select public" on public.avaliacoes
  for select using (true);

drop policy if exists "avaliacoes insert own purchase" on public.avaliacoes;
create policy "avaliacoes insert own purchase" on public.avaliacoes
  for insert with check (
    customer_id = auth.uid()
    and exists (
      select 1 from public.orders o
      where o.customer_id = auth.uid()
        and o.status = 'PAGO'
        and o.items @> jsonb_build_array(jsonb_build_object('productId', product_id::text))
    )
  );

drop policy if exists "avaliacoes update own" on public.avaliacoes;
create policy "avaliacoes update own" on public.avaliacoes
  for update using (customer_id = auth.uid()) with check (customer_id = auth.uid());

drop policy if exists "avaliacoes delete own or admin" on public.avaliacoes;
create policy "avaliacoes delete own or admin" on public.avaliacoes
  for delete using (customer_id = auth.uid() or public.is_admin());

create or replace function public.avaliacoes_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_avaliacoes_updated_at on public.avaliacoes;
create trigger trg_avaliacoes_updated_at
  before update on public.avaliacoes
  for each row execute function public.avaliacoes_set_updated_at();


-- =====================================================================================
-- 19) SORTEIOS
-- =====================================================================================
create table if not exists public.sorteios (
  id                  uuid primary key default gen_random_uuid(),
  titulo              text not null,
  premio              text not null,
  dias                integer,
  data_sorteio        date not null,
  status              text not null default 'aberto' check (status in ('aberto','finalizado')),
  ganhador_profile_id uuid references public.profiles(id) on delete set null,
  ganhador_codigo     text,
  ganhador_nome       text,
  created_at          timestamptz not null default now(),
  finalizado_em       timestamptz
);

alter table public.sorteios enable row level security;

drop policy if exists "sorteios_select_public" on public.sorteios;
create policy "sorteios_select_public" on public.sorteios
  for select using (true);

drop policy if exists "sorteios_admin_all" on public.sorteios;
create policy "sorteios_admin_all" on public.sorteios
  for all using (public.is_admin()) with check (public.is_admin());

-- lista clientes reais (com código e com compra confirmada) pra alimentar a roleta
create or replace function public.sorteio_listar_participantes()
returns table (codigo_cliente text, nome text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
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

create or replace function public.sorteio_definir_ganhador(p_sorteio_id uuid, p_codigo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile record;
begin
  if not public.is_admin() then
    raise exception 'Acesso negado: apenas administradores podem definir o ganhador.';
  end if;

  select id, full_name into v_profile
  from public.profiles
  where codigo_cliente = p_codigo;

  if v_profile.id is null then
    raise exception 'Cliente com código % não encontrado.', p_codigo;
  end if;

  update public.sorteios
  set status              = 'finalizado',
      ganhador_profile_id = v_profile.id,
      ganhador_codigo     = p_codigo,
      ganhador_nome       = coalesce(v_profile.full_name, 'Cliente'),
      finalizado_em       = now()
  where id = p_sorteio_id;
end;
$$;

grant execute on function public.sorteio_definir_ganhador(uuid, text) to authenticated;


-- =====================================================================================
-- 20) TICKETS — central de suporte
-- =====================================================================================
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
create index if not exists tickets_status_idx      on public.tickets(status);

create table if not exists public.ticket_mensagens (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.tickets(id) on delete cascade,
  sender_role  text not null check (sender_role in ('client','admin')),
  message_text text not null,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists ticket_mensagens_ticket_id_idx on public.ticket_mensagens(ticket_id);

create or replace function public.tickets_touch_updated_at()
returns trigger language plpgsql as $$
begin
  update public.tickets set updated_at = now() where id = new.ticket_id;
  return new;
end;
$$;

drop trigger if exists trg_ticket_mensagens_touch on public.ticket_mensagens;
create trigger trg_ticket_mensagens_touch
  after insert on public.ticket_mensagens
  for each row execute function public.tickets_touch_updated_at();

alter table public.tickets          enable row level security;
alter table public.ticket_mensagens enable row level security;

drop policy if exists "tickets_select_own_or_admin" on public.tickets;
create policy "tickets_select_own_or_admin" on public.tickets
  for select using (customer_id = auth.uid() or public.is_admin());

drop policy if exists "tickets_insert_own" on public.tickets;
create policy "tickets_insert_own" on public.tickets
  for insert with check (customer_id = auth.uid());

drop policy if exists "tickets_update_own_or_admin" on public.tickets;
create policy "tickets_update_own_or_admin" on public.tickets
  for update using (customer_id = auth.uid() or public.is_admin());

drop policy if exists "ticket_mensagens_select" on public.ticket_mensagens;
create policy "ticket_mensagens_select" on public.ticket_mensagens
  for select using (
    public.is_admin()
    or exists (select 1 from public.tickets t where t.id = ticket_mensagens.ticket_id and t.customer_id = auth.uid())
  );

drop policy if exists "ticket_mensagens_insert" on public.ticket_mensagens;
create policy "ticket_mensagens_insert" on public.ticket_mensagens
  for insert with check (
    (public.is_admin() and sender_role = 'admin')
    or exists (
      select 1 from public.tickets t
      where t.id = ticket_mensagens.ticket_id
        and t.customer_id = auth.uid()
        and sender_role = 'client'
    )
  );

drop policy if exists "ticket_mensagens_update" on public.ticket_mensagens;
create policy "ticket_mensagens_update" on public.ticket_mensagens
  for update using (
    public.is_admin()
    or exists (select 1 from public.tickets t where t.id = ticket_mensagens.ticket_id and t.customer_id = auth.uid())
  );

do $$
begin
  alter publication supabase_realtime add table public.ticket_mensagens;
exception when others then
  raise notice 'ticket_mensagens já estava no realtime (%).', sqlerrm;
end $$;


-- =====================================================================================
-- 21) PRODUCT_VIEWS — o que cada cliente já olhou (usado na aba "Contas" do admin)
-- =====================================================================================
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

drop policy if exists "product_views admin select" on public.product_views;
create policy "product_views admin select" on public.product_views
  for select using (public.is_admin());

drop policy if exists "product_views insert own" on public.product_views;
create policy "product_views insert own" on public.product_views
  for insert with check (cliente_id = auth.uid());


-- =====================================================================================
-- 22) STORAGE — buckets públicos de imagem
-- =====================================================================================
insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('site-assets', 'site-assets', true)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('chat-uploads', 'chat-uploads', true)
  on conflict (id) do nothing;

drop policy if exists "public read product-images" on storage.objects;
create policy "public read product-images" on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists "public read site-assets" on storage.objects;
create policy "public read site-assets" on storage.objects
  for select using (bucket_id = 'site-assets');

drop policy if exists "chat-uploads leitura publica" on storage.objects;
create policy "chat-uploads leitura publica" on storage.objects
  for select using (bucket_id = 'chat-uploads');

drop policy if exists "admin upload product-images" on storage.objects;
create policy "admin upload product-images" on storage.objects
  for insert with check (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin update product-images" on storage.objects;
create policy "admin update product-images" on storage.objects
  for update using (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin delete product-images" on storage.objects;
create policy "admin delete product-images" on storage.objects
  for delete using (bucket_id = 'product-images' and public.is_admin());

drop policy if exists "admin upload site-assets" on storage.objects;
create policy "admin upload site-assets" on storage.objects
  for insert with check (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "admin update site-assets" on storage.objects;
create policy "admin update site-assets" on storage.objects
  for update using (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "admin delete site-assets" on storage.objects;
create policy "admin delete site-assets" on storage.objects
  for delete using (bucket_id = 'site-assets' and public.is_admin());

drop policy if exists "chat-uploads upload autenticado" on storage.objects;
create policy "chat-uploads upload autenticado" on storage.objects
  for insert to authenticated with check (bucket_id = 'chat-uploads');

drop policy if exists "chat-uploads update autor" on storage.objects;
create policy "chat-uploads update autor" on storage.objects
  for update to authenticated using (bucket_id = 'chat-uploads' and owner = auth.uid());


-- =====================================================================================
-- 23) MIGRAÇÃO — converte códigos de afiliado antigos (ex: "MARIA482") para #0000
-- =====================================================================================
-- Rode só uma vez; depois disso ela não encontra mais nada pra converter.
-- Os clientes afetados precisam ser avisados do novo código (o admin pode usar o
-- botão "↻ Reenviar código" no painel).
-- =====================================================================================
do $$
declare
  r record;
  v_novo text;
begin
  for r in
    select id, codigo_afiliado from public.profiles
    where is_afiliado = true
      and codigo_afiliado is not null
      and codigo_afiliado !~ '^#[0-9]{4}$'
  loop
    v_novo := public.gerar_codigo_indicacao();
    update public.profiles set codigo_afiliado = v_novo where id = r.id;
    raise notice 'Código de afiliado convertido: % -> %', r.codigo_afiliado, v_novo;
  end loop;
end $$;

-- Garante que todo código de anunciante também siga o formato #0000
do $$
declare
  r record;
  v_novo text;
begin
  for r in
    select id, codigo from public.anunciantes where codigo !~ '^#[0-9]{4}$'
  loop
    v_novo := public.gerar_codigo_indicacao();
    update public.anunciantes set codigo = v_novo where id = r.id;
    raise notice 'Código de anunciante convertido: % -> %', r.codigo, v_novo;
  end loop;
end $$;


-- =====================================================================================
-- 24) PASSOS MANUAIS FINAIS (fazer uma vez só)
-- =====================================================================================
--
-- A) TOKEN DO MERCADO PAGO
--    Pegue seu Access Token de produção em:
--      Mercado Pago → Seu negócio → Configurações → Gestão e administração →
--      Credenciais → Credenciais de produção → Access Token
--
--    Depois rode (trocando pelo SEU token):
--
--      select vault.create_secret('APP_USR-SEU-TOKEN-AQUI', 'mp_access_token');
--
--    Se já existir e você quiser trocar:
--
--      select vault.update_secret(
--        (select id from vault.secrets where name = 'mp_access_token'),
--        'APP_USR-NOVO-TOKEN-AQUI'
--      );
--
--
-- B) VIRAR ADMINISTRADOR
--    1. Crie sua conta normalmente pelo site (botão "Login" → "Criar conta").
--    2. Depois rode isto, trocando pelo e-mail que você cadastrou:
--
--      update public.profiles set role = 'admin'
--      where id = (select id from auth.users where email = 'SEU-EMAIL@AQUI.com');
--
--    A partir daí essa conta entra em /#admin. Contas sem role = 'admin' são
--    bloqueadas e deslogadas automaticamente ao tentar.
--
--
-- C) CONFERIR SE ESTÁ TUDO NO LUGAR (opcional)
--
--      select routine_name from information_schema.routines
--      where routine_schema = 'public' order by routine_name;
--
--      select tablename from pg_tables where schemaname = 'public' order by tablename;
--
--      -- deve retornar exatamente 1 linha (uma única versão de criar_pix):
--      select count(*) from pg_proc p
--      join pg_namespace n on n.oid = p.pronamespace
--      where n.nspname = 'public' and p.proname = 'criar_pix';
--
-- =====================================================================================
-- FIM DO SCRIPT
-- =====================================================================================
-- =====================================================================================
-- FIM DO SCRIPT
-- =====================================================================================
