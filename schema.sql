-- ============================================================
-- SCHEMA NOVASTORE — rode este script inteiro no Supabase
-- (Painel do Supabase → SQL Editor → New query → cole tudo → Run)
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- PRODUTOS ----------
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  description text not null default '',
  type text not null default 'UNICO' check (type in ('UNICO','ASSINATURA')),
  price numeric(10,2),               -- usado quando type = UNICO
  category text,
  image_url text,                    -- imagem principal
  images jsonb not null default '[]',-- galeria extra: ["url1","url2"]
  plans jsonb not null default '[]', -- assinatura: [{"name":"7 dias","durationDays":7,"price":29.9,"recurring":false}]
  stock int,                         -- null = ilimitado
  featured boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- PEDIDOS ----------
create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_email text not null,
  items jsonb not null,              -- [{productId,planId,name,planName,price,quantity}]
  total numeric(10,2) not null,
  status text not null default 'PENDENTE' check (status in ('PENDENTE','PAGO','CANCELADO','EXPIRADO')),
  pix_id text,
  pix_qr_code text,
  pix_qr_code_base64 text,
  pix_expires_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- SEGURANÇA (RLS) ----------
alter table products enable row level security;
alter table orders enable row level security;

-- Qualquer visitante pode LER produtos ativos
drop policy if exists "produtos_leitura_publica" on products;
create policy "produtos_leitura_publica"
  on products for select
  using (active = true);

-- Somente usuários autenticados (você, logado no admin) podem criar/editar/excluir produtos
drop policy if exists "produtos_escrita_admin" on products;
create policy "produtos_escrita_admin"
  on products for all
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- Também permite ao admin ver produtos inativos
drop policy if exists "produtos_leitura_admin" on products;
create policy "produtos_leitura_admin"
  on products for select
  using (auth.role() = 'authenticated');

-- Pedidos: qualquer visitante pode CRIAR um pedido (checkout),
-- mas não pode ler pedidos de outras pessoas nem alterar status/pix (isso só a Edge Function faz, com a service role).
drop policy if exists "pedidos_criar_publico" on orders;
create policy "pedidos_criar_publico"
  on orders for insert
  with check (status = 'PENDENTE');

drop policy if exists "pedidos_leitura_admin" on orders;
create policy "pedidos_leitura_admin"
  on orders for select
  using (auth.role() = 'authenticated');

drop policy if exists "pedidos_update_admin" on orders;
create policy "pedidos_update_admin"
  on orders for update
  using (auth.role() = 'authenticated');

-- ---------- STORAGE (imagens dos produtos) ----------
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "imagens_leitura_publica" on storage.objects;
create policy "imagens_leitura_publica"
  on storage.objects for select
  using (bucket_id = 'product-images');

drop policy if exists "imagens_upload_admin" on storage.objects;
create policy "imagens_upload_admin"
  on storage.objects for insert
  with check (bucket_id = 'product-images' and auth.role() = 'authenticated');

drop policy if exists "imagens_delete_admin" on storage.objects;
create policy "imagens_delete_admin"
  on storage.objects for delete
  using (bucket_id = 'product-images' and auth.role() = 'authenticated');

-- ---------- DADOS DE EXEMPLO (opcional, pode apagar) ----------
insert into products (name, slug, description, type, price, category, image_url, featured)
values (
  'Licença Vitalícia PRO',
  'licenca-vitalicia-pro',
  'Acesso permanente a todas as ferramentas da plataforma, sem mensalidades.',
  'UNICO', 249.90, 'Licenças',
  'https://images.unsplash.com/photo-1518770660439-4636190af475?w=800',
  true
) on conflict (slug) do nothing;

insert into products (name, slug, description, type, category, image_url, plans, featured)
values (
  'Plano PRO',
  'plano-pro',
  'Acesso completo à plataforma, com liberação automática após confirmação do Pix.',
  'ASSINATURA', 'Assinaturas',
  'https://images.unsplash.com/photo-1551288049-bebda4e38f71?w=800',
  '[
    {"name":"1 dia","durationDays":1,"price":9.90,"recurring":false},
    {"name":"7 dias","durationDays":7,"price":29.90,"recurring":false},
    {"name":"15 dias","durationDays":15,"price":49.90,"recurring":false},
    {"name":"30 dias (Mensal)","durationDays":30,"price":79.90,"recurring":true}
  ]'::jsonb,
  true
) on conflict (slug) do nothing;
