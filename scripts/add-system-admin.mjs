// 追加 SystemAdmin 付与（上流 add-system-admin.sh 相当）。
//
// realm import で初期 admin（/SystemAdmin）が 1 名 seed されるが、2 人目以降を SystemAdmin に
// する手段がオンプレに無かった。サービスアカウント client で Keycloak Admin REST を叩き、
// 対象ユーザー（一度ログイン済み＝Keycloak に存在）を SystemAdmin グループへ加える。
//   1. email exact でユーザー解決（未存在ならエラー＝先に create-user.mjs / ログインが必要）
//   2. SystemAdmin グループ id を /groups?search で解決
//   3. PUT /users/{id}/groups/{gid}（冪等）
//
// 実行（deploy リポで、api コンテナ内）：
//   set -a && . ./.env && set +a && \
//   docker compose exec -T \
//     -e KEYCLOAK_ADMIN_CLIENT_SECRET="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
//     -e TARGET_EMAIL="user@example.com" \
//     api node --input-type=module - < scripts/add-system-admin.mjs
//
// secrets オーバーレイ運用時は _FILE を自動解決（-e 不要）。secret は標準出力に出さない。

import { readFileSync } from 'node:fs';

function readSecret(name) {
  const file = process.env[`${name}_FILE`];
  if (file) {
    return readFileSync(file, 'utf8').trim();
  }
  return process.env[name];
}

const BASE = (process.env.KEYCLOAK_ADMIN_BASE_URL ?? 'http://keycloak:8080').replace(/\/$/, '');
const REALM = process.env.KEYCLOAK_ADMIN_REALM ?? 'genai-realm';
const CLIENT_ID = process.env.KEYCLOAK_ADMIN_CLIENT_ID ?? 'genai-ai-api-admin';
const CLIENT_SECRET = readSecret('KEYCLOAK_ADMIN_CLIENT_SECRET');
const GROUP = process.env.TARGET_GROUP ?? 'SystemAdmin';

const email = process.env.TARGET_EMAIL;
if (!email) {
  console.error('TARGET_EMAIL が未設定です。-e TARGET_EMAIL="user@example.com" を渡してください。');
  process.exit(1);
}
if (!CLIENT_SECRET) {
  console.error('KEYCLOAK_ADMIN_CLIENT_SECRET（または _FILE）が未設定です。');
  process.exit(1);
}

async function getAdminToken() {
  const res = await fetch(`${BASE}/realms/${encodeURIComponent(REALM)}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'client_credentials', client_id: CLIENT_ID, client_secret: CLIENT_SECRET }),
  });
  if (!res.ok) {
    throw new Error(`admin token request failed: ${res.status}`);
  }
  const j = await res.json();
  if (!j.access_token) {
    throw new Error('admin token response missing access_token');
  }
  return j.access_token;
}

const token = await getAdminToken();
const authz = { authorization: `Bearer ${token}` };

// 1. ユーザー解決。
const findRes = await fetch(
  `${BASE}/admin/realms/${encodeURIComponent(REALM)}/users?email=${encodeURIComponent(email)}&exact=true`,
  { headers: authz },
);
if (!findRes.ok) {
  console.error(`[find] 失敗 status=${findRes.status}`);
  process.exit(1);
}
const users = await findRes.json();
const userId = Array.isArray(users) ? users.find((u) => typeof u.id === 'string')?.id : undefined;
if (!userId) {
  console.error(`[find] 未存在: ${email}`);
  console.error('  → 先に create-user.mjs で作成し、本人が一度ログインしてください。');
  process.exit(1);
}

// 2. グループ id 解決。
const groupRes = await fetch(
  `${BASE}/admin/realms/${encodeURIComponent(REALM)}/groups?search=${encodeURIComponent(GROUP)}`,
  { headers: authz },
);
if (!groupRes.ok) {
  console.error(`[group] 失敗 status=${groupRes.status}`);
  process.exit(1);
}
const groups = await groupRes.json();
const groupId = Array.isArray(groups) ? groups.find((g) => g.name === GROUP && typeof g.id === 'string')?.id : undefined;
if (!groupId) {
  console.error(`[group] グループ未検出: ${GROUP}`);
  process.exit(1);
}

// 3. グループ加入（PUT は冪等）。
const putRes = await fetch(
  `${BASE}/admin/realms/${encodeURIComponent(REALM)}/users/${encodeURIComponent(userId)}/groups/${encodeURIComponent(groupId)}`,
  { method: 'PUT', headers: authz },
);
if (!putRes.ok) {
  console.error(`[grant] 失敗 status=${putRes.status} body=${await putRes.text()}`);
  process.exit(1);
}

console.log(`[add-system-admin] ${email} を ${GROUP} に付与（再ログインで反映）。`);
console.log('[result] add-system-admin OK');
