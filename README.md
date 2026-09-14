# NOVASTORE — um único arquivo HTML (loja + admin) + Supabase

Agora é **um arquivo só**: `index.html`. A loja e o painel administrativo moram no mesmo
arquivo — você acessa a parte de admin colocando `#admin` no final da URL do site.

## Arquivos

```
index.html                          → SITE COMPLETO: loja (padrão) + admin (em #admin)
schema.sql                          → script para criar as tabelas no Supabase
supabase/functions/criar-pix/       → Edge Function que gera a cobrança Pix (Mercado Pago)
supabase/functions/webhook-pix/     → Edge Function que confirma o pagamento automaticamente
```

Só o `index.html` precisa ir para o GitHub Pages. A pasta `supabase/` é usada uma vez,
localmente, para publicar as Edge Functions (explicado no Passo 5).

---

## Como acessar cada parte

- **Loja (cliente):** `https://seusite.com/` (ou `index.html` local)
- **Painel admin (você):** `https://seusite.com/#admin`

Como é tudo estático, não existe "senha de URL" de verdade — qualquer um pode digitar
`#admin` e ver a **tela de login**. Isso é seguro, porque sem o e-mail/senha corretos
(criados no seu Supabase) ninguém consegue entrar de fato nem alterar nada — as regras
de segurança (RLS) do banco bloqueiam qualquer escrita de quem não estiver autenticado.

---

## Passo 1 — Criar o projeto no Supabase

1. Crie uma conta grátis em [supabase.com](https://supabase.com) e clique em **New Project**
2. Quando terminar de criar, vá em **Project Settings → API** e copie:
   - **Project URL** (ex: `https://abcxyz.supabase.co`)
   - **anon public key** (uma chave longa)

## Passo 2 — Criar as tabelas

1. No painel do Supabase: **SQL Editor → New query**
2. Cole todo o conteúdo do arquivo `schema.sql` e clique em **Run**
3. Isso cria as tabelas `products` e `orders`, as permissões (RLS), o bucket de imagens
   `product-images`, e 2 produtos de exemplo

## Passo 3 — Criar seu usuário admin

1. **Authentication → Users → Add user**
2. Preencha seu e-mail e uma senha forte (é com isso que você entra em `#admin`)
3. Marque "Auto Confirm User"

## Passo 4 — Configurar o arquivo

Abra `index.html` num editor de texto e edite estas 3 linhas perto do topo:

```js
window.SUPABASE_URL = "https://SEU-PROJETO.supabase.co";
window.SUPABASE_ANON_KEY = "SUA_CHAVE_ANON_PUBLICA_AQUI";
window.CRIAR_PIX_URL = "https://SEU-PROJETO.supabase.co/functions/v1/criar-pix";
```

## Passo 5 — Publicar as Edge Functions (geração do Pix)

Necessário porque a chave secreta do Mercado Pago não pode ficar em HTML público.

1. `npm install -g supabase`
2. `supabase login`
3. Na pasta do projeto: `supabase link --project-ref SEU_PROJECT_REF` (o ref está na URL do painel)
4. `supabase secrets set MERCADOPAGO_ACCESS_TOKEN=APP_USR-xxxxxxxxxxxx`
   (pegue em [Mercado Pago Developers → Credenciais](https://www.mercadopago.com.br/developers/panel))
5. `supabase functions deploy criar-pix`
6. `supabase functions deploy webhook-pix --no-verify-jwt`
7. No Mercado Pago: **Developers → Sua aplicação → Webhooks**, cole:
   `https://SEU-PROJETO.supabase.co/functions/v1/webhook-pix`, evento **Pagamentos**

> Sem publicar as functions, a loja funciona normalmente, só o botão "Gerar Pix" não vai responder.

## Passo 6 — Publicar no GitHub Pages

1. Crie um repositório e suba o `index.html` (pode subir a pasta `supabase/` também, sem problema)
2. **Settings → Pages** → Source: branch `main`, pasta `/` → Save
3. Em 1-2 minutos: `https://seu-usuario.github.io/nome-do-repositorio/`

## Uso do dia a dia

- Loja: os produtos aparecem automaticamente vindos do Supabase
- Admin (`#admin`): cadastre produtos (compra única ou assinatura com planos), suba imagens
- Carrinho: ao abrir, 2 produtos aleatórios aparecem como "Oferta especial"
- Pedidos pagos: acompanhe na tabela `orders` pelo **Table Editor** do Supabase

Qualquer ajuste — cores, textos, nova seção — é só pedir.
